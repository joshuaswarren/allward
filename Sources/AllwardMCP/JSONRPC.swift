import Foundation

public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

public enum JSONRPCID: Hashable, Sendable, Codable {
    case integer(Int64)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Hashable, Sendable, Codable {
    public var jsonrpc: String
    public var id: JSONRPCID?
    public var method: String
    public var params: JSONValue?
    public var metadata: JSONValue?

    public init(
        id: JSONRPCID? = nil,
        method: String,
        params: JSONValue? = nil,
        metadata: JSONValue? = nil
    ) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
        case metadata = "_meta"
    }
}

public struct JSONRPCErrorObject: Hashable, Sendable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse: Hashable, Sendable, Codable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: JSONValue?
    public var error: JSONRPCErrorObject?

    public init(id: JSONRPCID, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID, error: JSONRPCErrorObject) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

public enum JSONRPCTransportStyle: String, Hashable, Sendable, Codable {
    case lineDelimited
    case contentLength
}

public enum JSONRPCFramingError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownTransportPrefix
    case malformedHeader
    case missingContentLength
    case invalidContentLength
    case headerTooLarge
    case messageTooLarge(Int)

    public var description: String {
        switch self {
        case .unknownTransportPrefix: "Expected JSON or a Content-Length header"
        case .malformedHeader: "The Content-Length header is not valid UTF-8"
        case .missingContentLength: "The frame has no Content-Length header"
        case .invalidContentLength: "The Content-Length value is not a non-negative integer"
        case .headerTooLarge: "The framing header exceeds the 16 KiB limit"
        case let .messageTooLarge(length): "The JSON-RPC message is \(length) bytes; the limit is 8 MiB"
        }
    }
}

public struct JSONRPCFramer: Sendable {
    public private(set) var style: JSONRPCTransportStyle?
    private var buffer = Data()
    private var expectedBodyLength: Int?

    public static let maximumHeaderLength = 16 * 1_024
    public static let maximumMessageLength = 8 * 1_024 * 1_024

    public init() {}

    public mutating func receive<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        try detectStyleIfPossible()
        guard let style else { return [] }

        switch style {
        case .lineDelimited:
            return try extractLines()
        case .contentLength:
            return try extractContentLengthFrames()
        }
    }

    public func frame(_ message: Data) throws -> Data {
        guard message.count <= Self.maximumMessageLength else {
            throw JSONRPCFramingError.messageTooLarge(message.count)
        }
        guard let style else { throw JSONRPCFramingError.unknownTransportPrefix }
        switch style {
        case .lineDelimited:
            return message + Data("\n".utf8)
        case .contentLength:
            return Data("Content-Length: \(message.count)\r\n\r\n".utf8) + message
        }
    }

    private mutating func detectStyleIfPossible() throws {
        guard style == nil else { return }
        guard let first = buffer.first(where: { !$0.isASCIISpace }) else { return }
        if first == 0x7B || first == 0x5B {
            style = .lineDelimited
        } else if first == 0x43 || first == 0x63 {
            style = .contentLength
        } else {
            throw JSONRPCFramingError.unknownTransportPrefix
        }
    }

    private mutating func extractLines() throws -> [Data] {
        var messages: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if line.allSatisfy({ $0.isASCIISpace }) { continue }
            guard line.count <= Self.maximumMessageLength else {
                throw JSONRPCFramingError.messageTooLarge(line.count)
            }
            messages.append(line)
        }
        guard buffer.count <= Self.maximumMessageLength else {
            throw JSONRPCFramingError.messageTooLarge(buffer.count)
        }
        return messages
    }

    private mutating func extractContentLengthFrames() throws -> [Data] {
        var messages: [Data] = []
        while true {
            if expectedBodyLength == nil {
                guard let boundary = headerBoundary() else {
                    if buffer.count > Self.maximumHeaderLength {
                        throw JSONRPCFramingError.headerTooLarge
                    }
                    return messages
                }
                guard boundary.start <= Self.maximumHeaderLength else {
                    throw JSONRPCFramingError.headerTooLarge
                }
                let header = Data(buffer[..<boundary.start])
                expectedBodyLength = try parseContentLength(header)
                buffer.removeSubrange(..<boundary.end)
            }
            guard let length = expectedBodyLength, buffer.count >= length else { return messages }
            messages.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length)
            expectedBodyLength = nil
        }
    }

    private func headerBoundary() -> (start: Data.Index, end: Data.Index)? {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            return (range.lowerBound, range.upperBound)
        }
        if let range = buffer.range(of: Data("\n\n".utf8)) {
            return (range.lowerBound, range.upperBound)
        }
        return nil
    }

    private func parseContentLength(_ headerData: Data) throws -> Int {
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw JSONRPCFramingError.malformedHeader
        }
        let lines = header.split(whereSeparator: \.isNewline)
        let values = lines.compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else {
                return nil
            }
            return fields[1].trimmingCharacters(in: .whitespaces)
        }
        guard !values.isEmpty else { throw JSONRPCFramingError.missingContentLength }
        guard values.count == 1 else { throw JSONRPCFramingError.invalidContentLength }
        let value = values[0]
        guard let length = Int(value), length >= 0 else {
            throw JSONRPCFramingError.invalidContentLength
        }
        guard length <= Self.maximumMessageLength else {
            throw JSONRPCFramingError.messageTooLarge(length)
        }
        return length
    }
}

private extension UInt8 {
    var isASCIISpace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
