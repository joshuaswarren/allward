import Foundation

public struct EscapeRecognizer: Sendable {
    public static let maximumParameters = 32
    public static let maximumIntermediates = 4
    public static let maximumStringPayload = 8_192

    private enum State: Sendable {
        case ground, escape, escapeIntermediate, csiEntry, csiParameter, csiIntermediate, csiIgnore
        case oscString, oscEscape, oscIgnore, oscIgnoreEscape
        case dcsString, dcsEscape, ignoredString, ignoredEscape
    }

    private var state: State = .ground
    private var decoder = UTF8Decoder()
    private var parameters: [Int?] = []
    private var currentParameter: Int?
    private var parameterSeparators: [UInt8] = []
    private var privateMarker: UInt8?
    private var intermediates: [UInt8] = []
    private var payload: [UInt8] = []

    public init() {
        parameters.reserveCapacity(Self.maximumParameters)
        parameterSeparators.reserveCapacity(Self.maximumParameters - 1)
        intermediates.reserveCapacity(Self.maximumIntermediates)
        payload.reserveCapacity(Self.maximumStringPayload)
    }

    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> [TerminalOperation] {
        var operations: [TerminalOperation] = []
        operations.reserveCapacity(bytes.count)
        for byte in bytes { consume(byte) { operations.append($0) } }
        return operations
    }

    public mutating func consume(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        if byte == 0x9C {
            switch state {
            case .oscString, .oscEscape:
                emitOSC(emit: emit)
                resetSequence()
                state = .ground
                return
            case .oscIgnore, .oscIgnoreEscape, .dcsString, .dcsEscape, .ignoredString, .ignoredEscape:
                resetSequence()
                state = .ground
                return
            case .ground where !decoder.hasPendingSequence:
                return
            default: break
            }
        }
        if byte == 0x18 || byte == 0x1A {
            decoder.finish { emit(.print(String($0))) }
            resetSequence(); state = .ground
            return
        }
        switch state {
        case .ground: consumeGround(byte, emit: emit)
        case .escape: consumeEscape(byte, emit: emit)
        case .escapeIntermediate: consumeEscapeIntermediate(byte, emit: emit)
        case .csiEntry, .csiParameter, .csiIntermediate: consumeCSI(byte, emit: emit)
        case .csiIgnore:
            if byte == 0x1B {
                resetSequence()
                state = .escape
            } else if (0x40...0x7E).contains(byte) {
                resetSequence()
                state = .ground
            }
        case .oscString: consumeString(byte, escapeState: .oscEscape, emit: emit)
        case .oscEscape: consumeStringEscape(byte, stringState: .oscString, emit: emit)
        case .dcsString: consumeString(byte, escapeState: .dcsEscape, emit: emit)
        case .oscIgnore:
            if byte == 0x07 {
                resetSequence()
                state = .ground
            } else if byte == 0x1B {
                state = .oscIgnoreEscape
            }
        case .oscIgnoreEscape:
            state = byte == 0x5C ? .ground : .oscIgnore
        case .dcsEscape: consumeStringEscape(byte, stringState: .dcsString, emit: emit)
        case .ignoredString:
            if byte == 0x1B { state = .ignoredEscape }
        case .ignoredEscape:
            state = byte == 0x5C ? .ground : .ignoredString
        }
    }

    private mutating func consumeGround(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        if decoder.hasPendingSequence && byte >= 0x80 {
            decoder.consume(byte) { emit(.print(String($0))) }
            return
        }
        switch byte {
        case 0x1B: decoder.finish { emit(.print(String($0))) }; resetSequence(); state = .escape
        case 0x9B: decoder.finish { emit(.print(String($0))) }; beginCSI()
        case 0x9D: decoder.finish { emit(.print(String($0))) }; beginString(.oscString)
        case 0x90: decoder.finish { emit(.print(String($0))) }; beginString(.dcsString)
        case 0x98, 0x9E, 0x9F: decoder.finish { emit(.print(String($0))) }; beginString(.ignoredString)
        case 0x00...0x1F, 0x7F:
            decoder.finish { emit(.print(String($0))) }
            if let control = C0Control(rawValue: byte) { emit(.control(control)) }
        default: decoder.consume(byte) { emit(.print(String($0))) }
        }
    }

    private mutating func consumeEscape(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        if let control = C0Control(rawValue: byte) { emit(.control(control)); return }
        switch byte {
        case 0x5B: beginCSI()
        case 0x5D: beginString(.oscString)
        case 0x50: beginString(.dcsString)
        case 0x58, 0x5E, 0x5F: beginString(.ignoredString)
        case 0x20...0x2F: intermediates.append(byte); state = .escapeIntermediate
        default: emitEscapeFinal(byte, emit: emit); resetSequence(); state = .ground
        }
    }

    private mutating func consumeEscapeIntermediate(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        if (0x20...0x2F).contains(byte) {
            guard intermediates.count < Self.maximumIntermediates else { resetSequence(); state = .ground; return }
            intermediates.append(byte)
        } else if (0x30...0x7E).contains(byte) {
            emitEscapeFinal(byte, emit: emit); resetSequence(); state = .ground
        } else { resetSequence(); state = .ground }
    }

    private mutating func consumeCSI(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        switch byte {
        case 0x30...0x39:
            state = .csiParameter
            let digit = Int(byte - 0x30)
            if let current = currentParameter {
                guard current <= (Int.max - digit) / 10 else { abortCSI(); return }
                currentParameter = current * 10 + digit
            } else { currentParameter = digit }
        case 0x3A, 0x3B:
            state = .csiParameter
            appendParameter()
            guard state != .csiIgnore, parameterSeparators.count < Self.maximumParameters - 1 else {
                abortCSI()
                return
            }
            parameterSeparators.append(byte)
        case 0x3C...0x3F where parameters.isEmpty && currentParameter == nil && intermediates.isEmpty:
            privateMarker = byte
        case 0x20...0x2F:
            appendParameterIfNeeded()
            guard state != .csiIgnore else { return }
            guard intermediates.count < Self.maximumIntermediates else { abortCSI(); return }
            intermediates.append(byte); state = .csiIntermediate
        case 0x40...0x7E:
            appendParameterIfNeeded()
            guard state != .csiIgnore else {
                resetSequence()
                state = .ground
                return
            }
            emitCSIFinal(byte, emit: emit)
            resetSequence()
            state = .ground
        case 0x00...0x1F:
            if let control = C0Control(rawValue: byte) { emit(.control(control)) }
        default: abortCSI()
        }
    }

    private mutating func consumeString(_ byte: UInt8, escapeState: State, emit: (TerminalOperation) -> Void) {
        if state == .oscString && byte == 0x07 {
            emitOSC(emit: emit); resetSequence(); state = .ground; return
        }
        if byte == 0x1B { state = escapeState; return }
        guard payload.count < Self.maximumStringPayload else {
            resetSequence()
            state = state == .oscString ? .oscIgnore : .ignoredString
            return
        }
        payload.append(byte)
    }

    private mutating func consumeStringEscape(_ byte: UInt8, stringState: State, emit: (TerminalOperation) -> Void) {
        if byte == 0x5C {
            if stringState == .oscString { emitOSC(emit: emit) }
            resetSequence(); state = .ground; return
        }
        guard payload.count + 2 <= Self.maximumStringPayload else {
            resetSequence()
            state = stringState == .oscString ? .oscIgnore : .ignoredString
            return
        }
        payload.append(0x1B); payload.append(byte); state = stringState
    }

    private mutating func beginCSI() { resetSequence(); state = .csiEntry }
    private mutating func beginString(_ newState: State) { resetSequence(); state = newState }

    private mutating func appendParameter() {
        guard parameters.count < Self.maximumParameters else { abortCSI(); return }
        parameters.append(currentParameter); currentParameter = nil
    }

    private mutating func appendParameterIfNeeded() {
        if currentParameter != nil || !parameters.isEmpty { appendParameter() }
    }

    private mutating func abortCSI() {
        currentParameter = nil
        parameters.removeAll(keepingCapacity: true)
        parameterSeparators.removeAll(keepingCapacity: true)
        intermediates.removeAll(keepingCapacity: true)
        state = .csiIgnore
    }

    private mutating func resetSequence() {
        parameters.removeAll(keepingCapacity: true); parameterSeparators.removeAll(keepingCapacity: true)
        currentParameter = nil; privateMarker = nil
        intermediates.removeAll(keepingCapacity: true); payload.removeAll(keepingCapacity: true)
    }

    private func parameter(_ index: Int, default fallback: Int = 1, zeroIsDefault: Bool = true) -> Int {
        guard parameters.indices.contains(index), let value = parameters[index] else { return fallback }
        return zeroIsDefault && value == 0 ? fallback : value
    }

    private mutating func emitEscapeFinal(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        switch (intermediates, byte) {
        case ([], 0x37): emit(.saveCursor)
        case ([], 0x38): emit(.restoreCursor)
        case ([], 0x3D): emit(.setApplicationKeypad(true))
        case ([], 0x3E): emit(.setApplicationKeypad(false))
        case ([], 0x44): emit(.index)
        case ([], 0x4D): emit(.reverseIndex)
        case ([], 0x45): emit(.nextLine)
        case ([], 0x48): emit(.setTabStop)
        case ([], 0x63): emit(.reset)
        case ([0x23], 0x38): emit(.alignmentTest)
        default: emit(.noOp)
        }
    }

    private mutating func emitCSIFinal(_ byte: UInt8, emit: (TerminalOperation) -> Void) {
        let first = parameter(0)
        let selective = privateMarker == 0x3F
        switch byte {
        case 0x41: emit(.cursorUp(first))
        case 0x42: emit(.cursorDown(first))
        case 0x43: emit(.cursorForward(first))
        case 0x44: emit(.cursorBackward(first))
        case 0x45: emit(.cursorNextLine(first))
        case 0x46: emit(.cursorPreviousLine(first))
        case 0x47, 0x60: emit(.cursorHorizontalAbsolute(first))
        case 0x64: emit(.cursorVerticalAbsolute(first))
        case 0x48, 0x66: emit(.cursorPosition(row: first, column: parameter(1)))
        case 0x4A:
            let mode = EraseMode(rawValue: parameter(0, default: 0, zeroIsDefault: false)) ?? .after
            emit(.eraseDisplay(mode, selective: selective))
        case 0x4B:
            let mode = EraseMode(rawValue: parameter(0, default: 0, zeroIsDefault: false)) ?? .after
            emit(.eraseLine(mode, selective: selective))
        case 0x58: emit(.eraseCharacters(first))
        case 0x40: emit(.insertCharacters(first))
        case 0x50: emit(.deleteCharacters(first))
        case 0x4C: emit(.insertLines(first))
        case 0x4D: emit(.deleteLines(first))
        case 0x53: emit(.scrollUp(first))
        case 0x54: emit(.scrollDown(first))
        case 0x72: emit(.setVerticalMargins(top: first, bottom: parameter(1, default: 0, zeroIsDefault: false)))
        case 0x73: parameters.count > 1 ? emit(.ignoreHorizontalMargins) : emit(.saveCursor)
        case 0x75: emit(.restoreCursor)
        case 0x6D: emit(.sgr(Self.parseSGR(parameters, separators: parameterSeparators)))
        case 0x68, 0x6C:
            if privateMarker == 0x3F {
                let modes = parameters.compactMap { $0 }.compactMap(TerminalMode.init(rawValue:))
                byte == 0x68 ? emit(.setModes(modes)) : emit(.resetModes(modes))
            } else if parameters.contains(where: { $0 == 4 }) {
                emit(.setInsertMode(byte == 0x68))
            }
        case 0x67:
            let value = parameter(0, default: 0, zeroIsDefault: false)
            if let mode = TabClearMode(rawValue: value) {
                emit(.clearTabStop(mode))
            }
        case 0x49: emit(.cursorForwardTab(first))
        case 0x5A: emit(.cursorBackwardTab(first))
        case 0x63:
            let response = privateMarker == 0x3E ? "\u{1B}[>1;0;0c" : "\u{1B}[?62;22c"
            emit(.respond(Array(response.utf8)))
        case 0x6E:
            let request = parameter(0, default: 0, zeroIsDefault: false)
            if request == 5 {
                let response = privateMarker == 0x3F ? "\u{1B}[?0n" : "\u{1B}[0n"
                emit(.respond(Array(response.utf8)))
            }
            if request == 6 { emit(.reportCursorPosition(privateMode: privateMarker == 0x3F)) }
        case 0x71 where intermediates == [0x22]:
            emit(.setProtection(parameter(0, default: 0, zeroIsDefault: false) == 1))
        default: emit(.noOp)
        }
    }

    private static func parseSGR(_ values: [Int?], separators: [UInt8]) -> [SGRParameter] {
        let raw = values.isEmpty ? [0] : values.map { $0 ?? 0 }
        var result: [SGRParameter] = []
        var index = 0
        while index < raw.count {
            let value = raw[index]
            if value == 4, separators.indices.contains(index), separators[index] == 0x3A,
               raw.indices.contains(index + 1)
            {
                switch raw[index + 1] {
                case 0: result.append(.flag(.underline, enabled: false))
                case 1: result.append(.flag(.underline, enabled: true))
                case 2: result.append(.flag(.doubleUnderline, enabled: true))
                case 3: result.append(.flag(.curlyUnderline, enabled: true))
                default: break
                }
                index += 2
                continue
            }
            switch value {
            case 0: result.append(.reset)
            case 1: result.append(.flag(.bold, enabled: true))
            case 2: result.append(.flag(.faint, enabled: true))
            case 3: result.append(.flag(.italic, enabled: true))
            case 4: result.append(.flag(.underline, enabled: true))
            case 5, 6: result.append(.flag(.blink, enabled: true))
            case 7: result.append(.flag(.inverse, enabled: true))
            case 8: result.append(.flag(.invisible, enabled: true))
            case 9: result.append(.flag(.strikethrough, enabled: true))
            case 21: result.append(.flag(.doubleUnderline, enabled: true))
            case 22: result.append(.flag(.bold, enabled: false)); result.append(.flag(.faint, enabled: false))
            case 23: result.append(.flag(.italic, enabled: false))
            case 24:
                result.append(.flag(.underline, enabled: false)); result.append(.flag(.doubleUnderline, enabled: false))
                result.append(.flag(.curlyUnderline, enabled: false))
            case 25: result.append(.flag(.blink, enabled: false))
            case 27: result.append(.flag(.inverse, enabled: false))
            case 28: result.append(.flag(.invisible, enabled: false))
            case 29: result.append(.flag(.strikethrough, enabled: false))
            case 30...37: result.append(.foreground(.indexed(UInt8(value - 30))))
            case 39: result.append(.foreground(.defaultForeground))
            case 40...47: result.append(.background(.indexed(UInt8(value - 40))))
            case 49: result.append(.background(.defaultBackground))
            case 90...97: result.append(.foreground(.indexed(UInt8(value - 90 + 8))))
            case 100...107: result.append(.background(.indexed(UInt8(value - 100 + 8))))
            case 38, 48, 58:
                if let parsed = parseExtendedColor(raw, separators: separators, at: index) {
                    if value == 38 { result.append(.foreground(parsed.color)) }
                    if value == 48 { result.append(.background(parsed.color)) }
                    if value == 58 { result.append(.underlineColor(parsed.color)) }
                    index += parsed.consumed
                }
            case 59: result.append(.underlineColor(nil))
            default: break
            }
            index += 1
        }
        return result
    }

    private static func parseExtendedColor(
        _ values: [Int],
        separators: [UInt8],
        at index: Int
    ) -> (color: TerminalColor, consumed: Int)? {
        guard values.indices.contains(index + 1) else { return nil }
        if values[index + 1] == 5, values.indices.contains(index + 2), (0...255).contains(values[index + 2]) {
            return (.indexed(UInt8(values[index + 2])), 2)
        }
        let usesColonColorspace = separators.indices.contains(index + 1)
            && separators[index] == 0x3A
            && separators[index + 1] == 0x3A
        if usesColonColorspace,
           values[index + 1] == 2,
           values.indices.contains(index + 5),
           values[index + 2] == 0
        {
            let components = values[(index + 3)...(index + 5)]
            guard components.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return (
                .rgb(UInt8(values[index + 3]), UInt8(values[index + 4]), UInt8(values[index + 5])),
                5
            )
        }
        guard values[index + 1] == 2, values.indices.contains(index + 4) else { return nil }
        let components = values[(index + 2)...(index + 4)]
        guard components.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (.rgb(UInt8(values[index + 2]), UInt8(values[index + 3]), UInt8(values[index + 4])), 4)
    }

    private mutating func emitOSC(emit: (TerminalOperation) -> Void) {
        let fields = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let command = fields.first.flatMap(Int.init) else { return }
        switch command {
        case 0, 1, 2: emit(.setTitle(fields.dropFirst().joined(separator: ";")))
        case 7: emit(.setWorkingDirectory(fields.dropFirst().joined(separator: ";")))
        case 8:
            let uri = fields.dropFirst(2).joined(separator: ";")
            emit(.setHyperlink(parameters: fields.count > 1 ? fields[1] : "", uri: uri.isEmpty ? nil : uri))
        case 133:
            guard fields.count > 1, let phase = CommandPhase(rawValue: fields[1]) else { return }
            var metadata: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { metadata[pair[0]] = pair[1] }
                else if phase == .finished, metadata["exit"] == nil { metadata["exit"] = field }
            }
            emit(.commandMarker(OSCCommandMarker(phase: phase, parameters: metadata)))
        case 4:
            var index = 1
            while index + 1 < fields.count {
                if let paletteIndex = UInt8(fields[index]) {
                    emit(.setPalette(index: paletteIndex, value: fields[index + 1]))
                }
                index += 2
            }
        case 10, 11: emit(.setDynamicColor(slot: command, value: fields.dropFirst().joined(separator: ";")))
        default: break
        }
    }
}
