public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}
public struct KeyEvent: Hashable, Sendable {
    public var characters: String
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(
        characters: String,
        keyCode: UInt16,
        shift: Bool,
        control: Bool,
        option: Bool,
        command: Bool
    ) {
        self.characters = characters
        self.keyCode = keyCode
        var modifiers: KeyModifiers = []
        if shift { modifiers.insert(.shift) }
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if command { modifiers.insert(.command) }
        self.modifiers = modifiers
    }
}


public enum TerminalKey: Hashable, Sendable {
    case character(String)
    case up, down, right, left, home, end, insert, delete, pageUp, pageDown
    case enter, tab, backtab, escape, backspace
    case function(Int)
    case keypadDigit(Int)
    case keypadDecimal, keypadEnter, keypadAdd, keypadSubtract, keypadMultiply, keypadDivide
}

public enum MouseButton: Int, Hashable, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case none = 3
    case wheelUp = 64
    case wheelDown = 65
}

public enum MouseEvent: Hashable, Sendable {
    case press(button: MouseButton, column: Int, row: Int, modifiers: KeyModifiers)
    case release(button: MouseButton, column: Int, row: Int, modifiers: KeyModifiers)
    case motion(button: MouseButton, column: Int, row: Int, modifiers: KeyModifiers)
}

public enum InputEncoder {
    public static func encode(keyEvent: KeyEvent, modes: TerminalModes) -> [UInt8]? {
        if let key = terminalKey(for: keyEvent.keyCode, shift: keyEvent.modifiers.contains(.shift)) {
            return self.key(key, modifiers: keyEvent.modifiers, modes: modes)
        }
        guard !keyEvent.characters.isEmpty, !keyEvent.modifiers.contains(.command) else { return nil }
        return key(.character(keyEvent.characters), modifiers: keyEvent.modifiers, modes: modes)
    }

    public static func encodePaste(_ text: String, bracketed: Bool) -> [UInt8] {
        let content = bytes(text)
        guard bracketed else { return content }
        return bytes("\u{1B}[200~") + content + bytes("\u{1B}[201~")
    }

    public static func encode(
        mouseButton: Int,
        pressed: Bool,
        row: Int,
        column: Int,
        modifiers: KeyModifiers,
        modes: TerminalModes
    ) -> [UInt8]? {
        guard let button = self.mouseButton(for: mouseButton) else { return nil }
        let event: MouseEvent = pressed
            ? .press(button: button, column: column, row: row, modifiers: modifiers)
            : .release(button: button, column: column, row: row, modifiers: modifiers)
        let result = mouse(event, modes: modes)
        return result.isEmpty ? nil : result
    }

    public static func encode(
        mouseMotion button: Int,
        row: Int,
        column: Int,
        modifiers: KeyModifiers,
        modes: TerminalModes
    ) -> [UInt8]? {
        guard let mouseButton = mouseButton(for: button) else { return nil }
        let result = mouse(
            .motion(button: mouseButton, column: column, row: row, modifiers: modifiers),
            modes: modes
        )
        return result.isEmpty ? nil : result
    }

    public static func key(
        _ key: TerminalKey,
        modifiers: KeyModifiers = [],
        modes: TerminalModes
    ) -> [UInt8] {
        let modifier = modifierParameter(modifiers)
        switch key {
        case .character(let text): return encodeCharacter(text, modifiers: modifiers)
        case .up: return cursorKey(final: "A", application: modes.applicationCursorKeys, modifier: modifier)
        case .down: return cursorKey(final: "B", application: modes.applicationCursorKeys, modifier: modifier)
        case .right: return cursorKey(final: "C", application: modes.applicationCursorKeys, modifier: modifier)
        case .left: return cursorKey(final: "D", application: modes.applicationCursorKeys, modifier: modifier)
        case .home: return cursorKey(final: "H", application: modes.applicationCursorKeys, modifier: modifier)
        case .end: return cursorKey(final: "F", application: modes.applicationCursorKeys, modifier: modifier)
        case .insert: return tildeKey(2, modifier: modifier)
        case .delete: return tildeKey(3, modifier: modifier)
        case .pageUp: return tildeKey(5, modifier: modifier)
        case .pageDown: return tildeKey(6, modifier: modifier)
        case .enter: return [0x0D]
        case .tab: return modifiers.contains(.shift) ? bytes("\u{1B}[Z") : [0x09]
        case .backtab: return bytes("\u{1B}[Z")
        case .escape: return [0x1B]
        case .backspace: return [0x7F]
        case .function(let number): return functionKey(number, modifier: modifier)
        case .keypadDigit(let digit):
            guard modes.applicationKeypad, (0...9).contains(digit) else { return bytes(String(digit)) }
            return bytes("\u{1B}O" + String(Unicode.Scalar(0x70 + digit)!))
        case .keypadDecimal: return modes.applicationKeypad ? bytes("\u{1B}On") : bytes(".")
        case .keypadEnter: return modes.applicationKeypad ? bytes("\u{1B}OM") : [0x0D]
        case .keypadAdd: return modes.applicationKeypad ? bytes("\u{1B}Ok") : bytes("+")
        case .keypadSubtract: return modes.applicationKeypad ? bytes("\u{1B}Om") : bytes("-")
        case .keypadMultiply: return modes.applicationKeypad ? bytes("\u{1B}Oj") : bytes("*")
        case .keypadDivide: return modes.applicationKeypad ? bytes("\u{1B}Oo") : bytes("/")
        }
    }

    public static func paste(_ text: String, modes: TerminalModes) -> [UInt8] {
        encodePaste(text, bracketed: modes.bracketedPaste)
    }

    public static func focus(_ focused: Bool, modes: TerminalModes) -> [UInt8] {
        guard modes.focusReporting else { return [] }
        return bytes(focused ? "\u{1B}[I" : "\u{1B}[O")
    }

    public static func mouse(_ event: MouseEvent, modes: TerminalModes) -> [UInt8] {
        guard modes.mouseTracking != .off else { return [] }
        let details: (button: MouseButton, column: Int, row: Int, modifiers: KeyModifiers, release: Bool, motion: Bool)
        switch event {
        case .press(let button, let column, let row, let modifiers):
            details = (button, column, row, modifiers, false, false)
        case .release(let button, let column, let row, let modifiers):
            guard modes.mouseTracking != .press else { return [] }
            details = (button, column, row, modifiers, true, false)
        case .motion(let button, let column, let row, let modifiers):
            guard modes.mouseTracking == .buttonMotion || modes.mouseTracking == .anyMotion else { return [] }
            if modes.mouseTracking == .buttonMotion, button == .none { return [] }
            details = (button, column, row, modifiers, false, true)
        }
        var code = details.release && modes.mouseEncoding == .x10 ? MouseButton.none.rawValue : details.button.rawValue
        if details.motion { code |= 32 }
        if details.modifiers.contains(.shift) { code |= 4 }
        if details.modifiers.contains(.option) { code |= 8 }
        if details.modifiers.contains(.control) { code |= 16 }
        let column = max(0, details.column) + 1
        let row = max(0, details.row) + 1
        if modes.mouseEncoding == .sgr {
            return bytes("\u{1B}[<\(code);\(column);\(row)\(details.release ? "m" : "M")")
        }
        guard column + 32 <= 255, row + 32 <= 255, code + 32 <= 255 else { return [] }
        return [0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(column + 32), UInt8(row + 32)]
    }

    private static func cursorKey(final: String, application: Bool, modifier: Int) -> [UInt8] {
        if modifier == 1 { return bytes(application ? "\u{1B}O\(final)" : "\u{1B}[\(final)") }
        return bytes("\u{1B}[1;\(modifier)\(final)")
    }

    private static func tildeKey(_ number: Int, modifier: Int) -> [UInt8] {
        bytes(modifier == 1 ? "\u{1B}[\(number)~" : "\u{1B}[\(number);\(modifier)~")
    }

    private static func functionKey(_ number: Int, modifier: Int) -> [UInt8] {
        if (1...4).contains(number) {
            let final = String(Unicode.Scalar(0x50 + number - 1)!)
            return bytes(modifier == 1 ? "\u{1B}O\(final)" : "\u{1B}[1;\(modifier)\(final)")
        }
        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24,
                     13: 25, 14: 26, 15: 28, 16: 29, 17: 31, 18: 32, 19: 33, 20: 34]
        guard let code = codes[number] else { return [] }
        return tildeKey(code, modifier: modifier)
    }

    private static func encodeCharacter(_ text: String, modifiers: KeyModifiers) -> [UInt8] {
        var result = bytes(text)
        if modifiers.contains(.control), result.count == 1 {
            let byte = result[0]
            if (0x40...0x5F).contains(byte) { result[0] = byte - 0x40 }
            else if (0x61...0x7A).contains(byte) { result[0] = byte - 0x60 }
        }
        if modifiers.contains(.option) { result.insert(0x1B, at: 0) }
        return result
    }

    private static func modifierParameter(_ modifiers: KeyModifiers) -> Int {
        1 + (modifiers.contains(.shift) ? 1 : 0)
            + (modifiers.contains(.option) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
            + (modifiers.contains(.command) ? 8 : 0)
    }

    private static func terminalKey(for keyCode: UInt16, shift: Bool) -> TerminalKey? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 115: .home
        case 119: .end
        case 114: .insert
        case 117: .delete
        case 116: .pageUp
        case 121: .pageDown
        case 36: .enter
        case 48: shift ? .backtab : .tab
        case 53: .escape
        case 51: .backspace
        case 122: .function(1)
        case 120: .function(2)
        case 99: .function(3)
        case 118: .function(4)
        case 96: .function(5)
        case 97: .function(6)
        case 98: .function(7)
        case 100: .function(8)
        case 101: .function(9)
        case 109: .function(10)
        case 103: .function(11)
        case 111: .function(12)
        case 82: .keypadDigit(0)
        case 83...89: .keypadDigit(Int(keyCode - 82))
        case 91: .keypadDigit(8)
        case 92: .keypadDigit(9)
        case 65: .keypadDecimal
        case 76: .keypadEnter
        case 69: .keypadAdd
        case 78: .keypadSubtract
        case 67: .keypadMultiply
        case 75: .keypadDivide
        default: nil
        }
    }

    private static func mouseButton(for appKitButton: Int) -> MouseButton? {
        switch appKitButton {
        case 0: .left
        case 1: .right
        case 2: .middle
        default: nil
        }
    }

    private static func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }
}
