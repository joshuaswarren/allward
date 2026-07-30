import Foundation

public struct MCPProtocolClientContext: Hashable, Sendable {
    public var assertedClientID: String?

    public init(assertedClientID: String? = nil) {
        self.assertedClientID = assertedClientID
    }
}

public enum MCPServerError: Error, Hashable, Sendable, CustomStringConvertible {
    case notInitialized
    case mixedProtocolEra
    case unsupportedProtocolVersion(String?)
    case invalidLifecycle(String)
    case invalidParameters(String)
    case unknownTool(String)

    public var code: String {
        switch self {
        case .notInitialized: "not_initialized"
        case .mixedProtocolEra: "mixed_protocol_era"
        case .unsupportedProtocolVersion: "unsupported_protocol_version"
        case .invalidLifecycle: "invalid_lifecycle"
        case .invalidParameters: "invalid_parameters"
        case .unknownTool: "unknown_tool"
        }
    }

    public var description: String {
        switch self {
        case .notInitialized:
            return "Initialize the MCP connection before calling this method"
        case .mixedProtocolEra:
            return "The connection is already locked to another MCP protocol era"
        case let .unsupportedProtocolVersion(version):
            let supported = MCPProtocolRevision.allCases.map(\.rawValue).joined(separator: " and ")
            return "Unsupported MCP protocol version \(version ?? "<missing>"); supported versions are \(supported)"
        case let .invalidLifecycle(message):
            return message
        case let .invalidParameters(message):
            return message
        case let .unknownTool(name):
            return "Unknown tool: \(name)"
        }
    }
}

public actor MCPServer {
    private enum Lifecycle: Sendable {
        case awaitingFirstRequest
        case awaitingLegacyInitialized
        case ready(MCPProtocolRevision)
        case shutDown
    }

    private let toolProvider: any MCPToolProviding
    private let serverName: String
    private let serverVersion: String
    private var lifecycle: Lifecycle = .awaitingFirstRequest
    private var clientContext = MCPProtocolClientContext()

    public init(
        toolProvider: any MCPToolProviding,
        serverName: String = "Allward",
        serverVersion: String = "1.0.0"
    ) {
        self.toolProvider = toolProvider
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    public var negotiatedRevision: MCPProtocolRevision? {
        switch lifecycle {
        case .awaitingFirstRequest, .awaitingLegacyInitialized, .shutDown: nil
        case let .ready(revision): revision
        }
    }

    public var isShutdown: Bool {
        if case .shutDown = lifecycle { true } else { false }
    }

    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        let id = request.id ?? .null
        guard request.jsonrpc == "2.0", !request.method.isEmpty else {
            return Self.error(id: id, code: .invalidRequest, message: "Invalid JSON-RPC 2.0 request")
        }

        do {
            let result = try await route(request)
            return JSONRPCResponse(id: id, result: result)
        } catch let error as MCPAuthorizationError {
            return Self.typedError(id: id, code: -32_001, type: error.code, message: error.description)
        } catch let error as MCPMutationLedgerError {
            return Self.typedError(id: id, code: -32_002, type: "mutation_ledger", message: error.description)
        } catch let error as MCPToolError {
            return Self.error(id: id, code: .invalidParams, message: error.description)
        } catch let error as MCPServerError {
            switch error {
            case .unknownTool:
                return Self.typedError(id: id, code: -32_004, type: error.code, message: error.description)
            case .invalidParameters:
                return Self.typedError(id: id, code: JSONRPCErrorCode.invalidParams.rawValue,
                                       type: error.code, message: error.description)
            default:
                return Self.typedError(id: id, code: -32_000, type: error.code, message: error.description)
            }
        } catch let error as MethodNotFound {
            return Self.error(
                id: id,
                code: .methodNotFound,
                message: "Method not found: \(error.method)"
            )
        } catch {
            return Self.typedError(
                id: id,
                code: JSONRPCErrorCode.internalError.rawValue,
                type: "internal_error",
                message: String(describing: error)
            )
        }
    }

    private func route(_ request: JSONRPCRequest) async throws -> JSONValue {
        switch lifecycle {
        case .awaitingFirstRequest:
            return try await handleFirstRequest(request)
        case .awaitingLegacyInitialized:
            guard request.method == "notifications/initialized", request.id == nil else {
                if request.method == "server/discover" { throw MCPServerError.mixedProtocolEra }
                throw MCPServerError.notInitialized
            }
            lifecycle = .ready(.legacy)
            return .null
        case let .ready(revision):
            return try await handleReady(request, revision: revision)
        case .shutDown:
            throw MCPServerError.invalidLifecycle("The MCP server has shut down")
        }
    }

    private func handleFirstRequest(_ request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            let parameters = try object(request.params, name: "initialize params")
            let version = parameters["protocolVersion"]?.stringValue
            guard version == MCPProtocolRevision.legacy.rawValue else {
                throw MCPServerError.unsupportedProtocolVersion(version)
            }
            clientContext = MCPProtocolClientContext(assertedClientID: Self.clientID(from: parameters["clientInfo"]))
            lifecycle = .awaitingLegacyInitialized
            return capabilities(revision: .legacy)
        case "server/discover":
            let metadata = try object(request.metadata, name: "modern _meta")
            let version = metadata["protocolVersion"]?.stringValue
            guard version == MCPProtocolRevision.modern.rawValue else {
                throw MCPServerError.unsupportedProtocolVersion(version)
            }
            guard metadata["clientInfo"]?.objectValue != nil else {
                throw MCPServerError.invalidParameters("Modern requests require _meta.clientInfo")
            }
            guard metadata["capabilities"]?.objectValue != nil else {
                throw MCPServerError.invalidParameters("Modern requests require _meta.capabilities")
            }
            clientContext = MCPProtocolClientContext(assertedClientID: Self.clientID(from: metadata["clientInfo"]))
            lifecycle = .ready(.modern)
            return capabilities(revision: .modern)
        default:
            throw MCPServerError.notInitialized
        }
    }

    private func handleReady(_ request: JSONRPCRequest, revision: MCPProtocolRevision) async throws -> JSONValue {
        if revision == .modern {
            try validateModernMetadata(request.metadata)
        }
        switch request.method {
        case "initialize", "notifications/initialized", "server/discover":
            throw MCPServerError.mixedProtocolEra
        case "ping":
            return .object([:])
        case "tools/list":
            let tools = await toolProvider.listTools()
            return .object(["tools": .array(try tools.map(Self.jsonValue))])
        case "tools/call":
            let parameters = try object(request.params, name: "tools/call params")
            guard let name = parameters["name"]?.stringValue else {
                throw MCPServerError.invalidParameters("tools/call requires a string name")
            }
            let arguments = parameters["arguments"] ?? .object([:])
            do {
                let result = try await toolProvider.callTool(name: name, arguments: arguments, context: clientContext)
                let text = try Self.jsonText(result)
                return .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "structuredContent": result,
                    "isError": .bool(false)
                ])
            } catch let error as MCPToolError {
                if case let .unknownTool(toolName) = error { throw MCPServerError.unknownTool(toolName) }
                throw error
            }
        case "shutdown":
            lifecycle = .shutDown
            return .null
        default:
            throw MethodNotFound(method: request.method)
        }
    }

    private func capabilities(revision: MCPProtocolRevision) -> JSONValue {
        .object([
            "protocolVersion": .string(revision.rawValue),
            "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])])
        ])
    }

    private func validateModernMetadata(_ metadataValue: JSONValue?) throws {
        let metadata = try object(metadataValue, name: "modern _meta")
        guard metadata["protocolVersion"]?.stringValue == MCPProtocolRevision.modern.rawValue else {
            throw MCPServerError.mixedProtocolEra
        }
        guard metadata["clientInfo"]?.objectValue != nil, metadata["capabilities"]?.objectValue != nil else {
            throw MCPServerError.invalidParameters("Modern requests require identity and capabilities in _meta")
        }
        let asserted = Self.clientID(from: metadata["clientInfo"])
        if let original = clientContext.assertedClientID, let asserted, original != asserted {
            throw MCPAuthorizationError.protocolIdentityMismatch
        }
    }

    private func object(_ value: JSONValue?, name: String) throws -> [String: JSONValue] {
        guard case let .object(object)? = value else {
            throw MCPServerError.invalidParameters("\(name) must be an object")
        }
        return object
    }

    private static func clientID(from value: JSONValue?) -> String? {
        guard case let .object(info)? = value else { return nil }
        return info["id"]?.stringValue ?? info["name"]?.stringValue
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func jsonText(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPServerError.invalidParameters("Tool result is not UTF-8 JSON")
        }
        return text
    }

    private static func error(
        id: JSONRPCID,
        code: JSONRPCErrorCode,
        message: String
    ) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCErrorObject(code: code.rawValue, message: message))
    }

    private static func typedError(id: JSONRPCID, code: Int, type: String, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            error: JSONRPCErrorObject(code: code, message: message, data: .object(["type": .string(type)]))
        )
    }

    private struct MethodNotFound: Error, Sendable {
        var method: String
    }
}
