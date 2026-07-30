import AllwardCore
import Foundation

public enum FrameCodecError: Error, Equatable, Sendable {
    case lineTooLong(limit: Int)
    case nestingTooDeep(limit: Int)
    case tooManyPlanEntries(limit: Int)
    case tooManyPermissionOptions(limit: Int)
    case reservedPublisherField(String)
    case malformedJSON
    case malformedFrame
    case unterminatedLine
}

public enum FrameDecodeResult: Equatable, Sendable {
    case frame(AllwardFrame)
    case ignoredUnknownFrame
    case rejected(FrameCodecError)
}

public struct FrameDecoder: Sendable {
    public static let maximumLineBytes = 256 * 1024
    public static let maximumNestingDepth = 32
    public static let maximumPlanEntries = 512
    public static let maximumPermissionOptions = 16
    private static let knownFrameKeys: Set<String> = [
        "grantRequest", "grantResponse", "publication", "decision", "decisionStatus",
        "decisionQuery", "decisionCancel", "decisionAck",
    ]


    private var line = Data()
    private var discardingOversizedLine = false

    public private(set) var ignoredUnknownFrameCount: UInt64 = 0
    public private(set) var rejectedBoundCount: UInt64 = 0

    public init() {
        line.reserveCapacity(Self.maximumLineBytes)
    }

    public var bufferedByteCount: Int { line.count }

    public mutating func append(_ bytes: Data) -> [FrameDecodeResult] {
        var results: [FrameDecodeResult] = []

        for byte in bytes {
            if discardingOversizedLine {
                if byte == 0x0A {
                    discardingOversizedLine = false
                }
                continue
            }

            if byte == 0x0A {
                if line.last == 0x0D {
                    line.removeLast()
                }
                if !line.isEmpty {
                    results.append(decodeLine(line))
                }
                line.removeAll(keepingCapacity: true)
                continue
            }

            guard line.count < Self.maximumLineBytes else {
                line.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
                rejectedBoundCount &+= 1
                results.append(.rejected(.lineTooLong(limit: Self.maximumLineBytes)))
                continue
            }
            line.append(byte)
        }

        return results
    }

    public mutating func finish() -> [FrameDecodeResult] {
        if discardingOversizedLine {
            discardingOversizedLine = false
            return []
        }
        guard !line.isEmpty else { return [] }
        line.removeAll(keepingCapacity: true)
        return [.rejected(.unterminatedLine)]
    }

    private mutating func decodeLine(_ data: Data) -> FrameDecodeResult {
        let preflight: JSONPreflight.Result
        do {
            preflight = try JSONPreflight.validate(data)
        } catch let error as FrameCodecError {
            if error.isBoundRejection {
                rejectedBoundCount &+= 1
            }
            return .rejected(error)
        } catch {
            return .rejected(.malformedJSON)
        }

        guard let rootKey = preflight.rootKey else {
            return .rejected(.malformedFrame)
        }
        guard Self.knownFrameKeys.contains(rootKey) else {
            ignoredUnknownFrameCount &+= 1
            return .ignoredUnknownFrame
        }

        if rootKey == "publication", let forbidden = preflight.reservedPublisherField {
            return .rejected(.reservedPublisherField(forbidden))
        }

        do {
            let raw = try JSONDecoder().decode(RawAllwardFrame.self, from: data)
            let converted = raw.frame
            ignoredUnknownFrameCount &+= UInt64(converted.ignoredCapabilities)
            return .frame(converted.frame)
        } catch {
            return .rejected(.malformedFrame)
        }
    }
}

public struct FrameEncoder: Sendable {
    public init() {}

    public func encode(_ frame: AllwardFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        guard data.count <= FrameDecoder.maximumLineBytes else {
            throw FrameCodecError.lineTooLong(limit: FrameDecoder.maximumLineBytes)
        }
        data.append(0x0A)
        return data
    }
}

private extension FrameCodecError {
    var isBoundRejection: Bool {
        switch self {
        case .lineTooLong, .nestingTooDeep, .tooManyPlanEntries, .tooManyPermissionOptions:
            true
        default:
            false
        }
    }
}

private enum RawAllwardFrame: Codable {
    case grantRequest(RawGrantRequest)
    case grantResponse(GrantResponse)
    case publication(PublicationFrame)
    case decision(DecisionFrame)
    case decisionStatus(DecisionStatusFrame)
    case decisionQuery(DecisionQueryFrame)
    case decisionCancel(DecisionCancelFrame)
    case decisionAck(DecisionAckFrame)

    var frame: (frame: AllwardFrame, ignoredCapabilities: Int) {
        switch self {
        case let .grantRequest(request):
            let capabilities = request.capabilities.compactMap(AllwardProtocolVersion.Capability.init(rawValue:))
            let ignored = request.capabilities.count - capabilities.count
            return (
                .grantRequest(
                    GrantRequest(
                        protocolMajor: request.protocolMajor,
                        capabilities: capabilities,
                        harness: request.harness,
                        publisherName: request.publisherName,
                        descriptor: request.descriptor,
                        sessionHint: request.sessionHint,
                        roomHint: request.roomHint,
                        requestedLeaseSeconds: request.requestedLeaseSeconds
                    )
                ),
                ignored
            )
        case let .grantResponse(response):
            return (.grantResponse(response), 0)
        case let .publication(publication):
            return (.publication(publication), 0)
        case let .decision(decision):
            return (.decision(decision), 0)
        case let .decisionStatus(status):
            return (.decisionStatus(status), 0)
        case let .decisionQuery(query):
            return (.decisionQuery(query), 0)
        case let .decisionCancel(cancel):
            return (.decisionCancel(cancel), 0)
        case let .decisionAck(acknowledgment):
            return (.decisionAck(acknowledgment), 0)
        }
    }
}

private struct RawGrantRequest: Codable {
    var protocolMajor: Int
    var capabilities: [String]
    var harness: String
    var publisherName: String
    var descriptor: String
    var sessionHint: String?
    var roomHint: String?
    var requestedLeaseSeconds: Double?
}

private struct JSONPreflight {
    struct Result {
        var rootKey: String?
        var reservedPublisherField: String?
    }

    static func validate(_ data: Data) throws -> Result {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
        return Result(rootKey: parser.rootKey, reservedPublisherField: parser.reservedPublisherField)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var rootKey: String?
        var reservedPublisherField: String?

        private static let reservedFields: Set<String> = [
            "provenance", "source", "recordSource", "record_source",
            "adapter", "adapterRef", "adapter_ref", "adapterReference", "adapter_reference",
            "room", "roomID", "room_id", "roomAuthority", "room_authority",
            "target", "publisherTargetKey", "publisher_target_key",
            "terminal", "terminalContent", "terminal_content", "terminalBytes", "terminal_bytes",
            "ptyBytes", "pty_bytes", "scrollback", "cells",
        ]

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0, semanticKey: nil)
            skipWhitespace()
            guard index == bytes.count else { throw FrameCodecError.malformedJSON }
        }

        mutating func parseValue(depth: Int, semanticKey: String?) throws {
            guard index < bytes.count else { throw FrameCodecError.malformedJSON }
            switch bytes[index] {
            case 0x7B:
                try parseObject(depth: depth + 1, semanticKey: semanticKey)
            case 0x5B:
                try parseArray(depth: depth + 1, semanticKey: semanticKey)
            case 0x22:
                _ = try parseString(capturing: false)
            case 0x74:
                try consumeLiteral("true")
            case 0x66:
                try consumeLiteral("false")
            case 0x6E:
                try consumeLiteral("null")
            case 0x2D, 0x30...0x39:
                try parseNumber()
            default:
                throw FrameCodecError.malformedJSON
            }
        }

        mutating func parseObject(depth: Int, semanticKey: String?) throws {
            guard depth <= FrameDecoder.maximumNestingDepth else {
                throw FrameCodecError.nestingTooDeep(limit: FrameDecoder.maximumNestingDepth)
            }
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }

            var memberIndex = 0
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw FrameCodecError.malformedJSON
                }
                let key = try parseString(capturing: true)
                if depth == 1, memberIndex == 0 {
                    rootKey = key ?? ""
                }
                if let key, Self.reservedFields.contains(key), reservedPublisherField == nil {
                    reservedPublisherField = key
                }
                skipWhitespace()
                guard consume(0x3A) else { throw FrameCodecError.malformedJSON }
                skipWhitespace()

                let childSemantic: String?
                if key == "plan" || key == "options" {
                    childSemantic = key
                } else if key == "_0" {
                    childSemantic = semanticKey
                } else {
                    childSemantic = nil
                }
                try parseValue(depth: depth, semanticKey: childSemantic)
                memberIndex += 1
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw FrameCodecError.malformedJSON }
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int, semanticKey: String?) throws {
            guard depth <= FrameDecoder.maximumNestingDepth else {
                throw FrameCodecError.nestingTooDeep(limit: FrameDecoder.maximumNestingDepth)
            }
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }

            var count = 0
            while true {
                try parseValue(depth: depth, semanticKey: nil)
                count += 1
                if semanticKey == "plan", count > FrameDecoder.maximumPlanEntries {
                    throw FrameCodecError.tooManyPlanEntries(limit: FrameDecoder.maximumPlanEntries)
                }
                if semanticKey == "options", count > FrameDecoder.maximumPermissionOptions {
                    throw FrameCodecError.tooManyPermissionOptions(limit: FrameDecoder.maximumPermissionOptions)
                }
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw FrameCodecError.malformedJSON }
                skipWhitespace()
            }
        }

        mutating func parseString(capturing: Bool) throws -> String? {
            guard consume(0x22) else { throw FrameCodecError.malformedJSON }
            var scalars = String.UnicodeScalarView()
            var canCapture = capturing

            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    return canCapture ? String(scalars) : nil
                }
                if byte < 0x20 { throw FrameCodecError.malformedJSON }

                if byte == 0x5C {
                    guard index < bytes.count else { throw FrameCodecError.malformedJSON }
                    let escape = bytes[index]
                    index += 1
                    let scalar: UnicodeScalar
                    switch escape {
                    case 0x22: scalar = "\""
                    case 0x5C: scalar = "\\"
                    case 0x2F: scalar = "/"
                    case 0x62: scalar = "\u{08}"
                    case 0x66: scalar = "\u{0C}"
                    case 0x6E: scalar = "\n"
                    case 0x72: scalar = "\r"
                    case 0x74: scalar = "\t"
                    case 0x75:
                        scalar = try parseUnicodeEscape()
                    default:
                        throw FrameCodecError.malformedJSON
                    }
                    if canCapture {
                        scalars.append(scalar)
                    }
                } else if byte < 0x80 {
                    if canCapture {
                        scalars.append(UnicodeScalar(byte))
                    }
                } else {
                    canCapture = false
                    try consumeUTF8Continuation(startingWith: byte)
                }

                if scalars.count > 64 {
                    canCapture = false
                    scalars.removeAll(keepingCapacity: false)
                }
            }
            throw FrameCodecError.malformedJSON
        }

        mutating func parseUnicodeEscape() throws -> UnicodeScalar {
            let first = try parseHexQuad()
            if (0xD800...0xDBFF).contains(first) {
                guard index + 2 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                    throw FrameCodecError.malformedJSON
                }
                index += 2
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw FrameCodecError.malformedJSON
                }
                let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = UnicodeScalar(value) else { throw FrameCodecError.malformedJSON }
                return scalar
            }
            guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(first) else {
                throw FrameCodecError.malformedJSON
            }
            return scalar
        }

        mutating func parseHexQuad() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw FrameCodecError.malformedJSON }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                value = value * 16 + UInt32(try hexValue(byte))
            }
            return value
        }

        mutating func consumeUTF8Continuation(startingWith byte: UInt8) throws {
            let continuationCount: Int
            switch byte {
            case 0xC2...0xDF: continuationCount = 1
            case 0xE0...0xEF: continuationCount = 2
            case 0xF0...0xF4: continuationCount = 3
            default: throw FrameCodecError.malformedJSON
            }
            guard index + continuationCount <= bytes.count else { throw FrameCodecError.malformedJSON }
            for _ in 0..<continuationCount {
                guard (0x80...0xBF).contains(bytes[index]) else { throw FrameCodecError.malformedJSON }
                index += 1
            }
        }

        mutating func parseNumber() throws {
            if consume(0x2D), index == bytes.count { throw FrameCodecError.malformedJSON }
            if consume(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw FrameCodecError.malformedJSON
                }
            } else {
                guard consumeDigits(minimum: 1) else { throw FrameCodecError.malformedJSON }
            }
            if consume(0x2E), !consumeDigits(minimum: 1) {
                throw FrameCodecError.malformedJSON
            }
            if consume(0x65) || consume(0x45) {
                _ = consume(0x2B) || consume(0x2D)
                guard consumeDigits(minimum: 1) else { throw FrameCodecError.malformedJSON }
            }
        }

        mutating func consumeDigits(minimum: Int) -> Bool {
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            return index - start >= minimum
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw FrameCodecError.malformedJSON
            }
            index += expected.count
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        func hexValue(_ byte: UInt8) throws -> UInt8 {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: throw FrameCodecError.malformedJSON
            }
        }
    }
}
