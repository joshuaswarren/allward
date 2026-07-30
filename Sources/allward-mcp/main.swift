import AllwardMCP
import Darwin
import Foundation

@main
struct AllwardMCPExecutable {
    static func main() async {
        do {
            try await run()
        } catch {
            writeStandardError("allward-mcp: \(error)\n")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let socketPath = ProcessInfo.processInfo.environment["ALLWARD_APP_SOCKET"] ?? defaultSocketPath()
        let control = try ControlSocketClient.connect(path: socketPath)
        var framer = JSONRPCFramer()
        var server: MCPServer?
        var activeGrantNamespace: String?

        while true {
            let bytes = FileHandle.standardInput.readData(ofLength: 16_384)
            if bytes.isEmpty {
                if let activeGrantNamespace {
                    try await control.staleAuthoredAuthority(namespace: activeGrantNamespace)
                }
                return
            }
            let messages = try framer.receive(bytes)
            for message in messages {
                let request: JSONRPCRequest
                do {
                    request = try JSONDecoder().decode(JSONRPCRequest.self, from: message)
                } catch {
                    try write(
                        JSONRPCResponse(
                            id: .null,
                            error: JSONRPCErrorObject(
                                code: JSONRPCErrorCode.parseError.rawValue,
                                message: "Invalid JSON-RPC JSON"
                            )
                        ),
                        using: framer
                    )
                    continue
                }

                if server == nil {
                    guard let revision = firstRevision(request) else {
                        if let id = request.id {
                            try write(
                                JSONRPCResponse(
                                    id: id,
                                    error: JSONRPCErrorObject(
                                        code: -32_000,
                                        message: "Initialize the MCP connection before calling this method",
                                        data: .object(["type": .string("not_initialized")])
                                    )
                                ),
                                using: framer
                            )
                        }
                        continue
                    }
                    guard let style = framer.style else { throw JSONRPCFramingError.unknownTransportPrefix }
                    let transport: MCPTransportAdapter = switch style {
                    case .lineDelimited: .stdioLineDelimited
                    case .contentLength: .stdioContentLength
                    }
                    let launcherNonce = UUID().uuidString.lowercased()
                    let channelNonce = UUID().uuidString.lowercased()
                    let presenterID = "pid-\(getpid())-\(UUID().uuidString.lowercased())"
                    let clientID = clientID(from: request, revision: revision) ?? "local-owner"
                    let targetScope = try await control.ownerGrantScope(
                        windowID: ProcessInfo.processInfo.environment["ALLWARD_WINDOW_ID"]
                    )
                    var capabilities = Set(MCPToolCapability.allCases)
                    capabilities.remove(.recoveryLookup)
                    // LIMITATION: App-issued signed presenter grants and revocation require the 1.x control contract.
                    let signature = Data(UUID().uuidString.utf8)
                    let grant = MCPGrant(
                        id: UUID(),
                        clientID: clientID,
                        invocationNamespace: UUID().uuidString.lowercased(),
                        serverInstanceAudience: "owner-socket:\(socketPath)",
                        protocolRevision: revision,
                        transport: transport,
                        launcherNonce: launcherNonce,
                        channelNonce: channelNonce,
                        presenterID: presenterID,
                        capabilities: capabilities,
                        targetScope: targetScope,
                        issuedAt: Date(),
                        expiresAt: Date().addingTimeInterval(60 * 60),
                        signature: signature
                    )
                    activeGrantNamespace = grant.invocationNamespace
                    let binding = MCPConnectionBinding(
                        serverInstanceAudience: grant.serverInstanceAudience,
                        protocolRevision: revision,
                        transport: transport,
                        launcherNonce: launcherNonce,
                        channelNonce: channelNonce,
                        presenterID: presenterID
                    )
                    let authorizer = CallerCapabilityAuthorizer(
                        grant: grant,
                        binding: binding,
                        authenticator: OwnerSocketGrantAuthenticator(grantID: grant.id, signature: signature)
                    )
                    let ledgerURL = URL(fileURLWithPath: socketPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent("mcp-ledger-\(stableLedgerID(for: grant.clientID)).json")
                    let ledger = MCPMutationLedger(storageURL: ledgerURL)
                    let tools = AllwardTools(control: control, authorizer: authorizer, ledger: ledger)
                    // LIMITATION: The typed control API cannot cancel an in-flight allward_run waiter mid-flight.
                    server = MCPServer(toolProvider: tools)
                }

                guard let server else { throw MCPServerError.notInitialized }
                let response = await server.handle(request)
                if request.id != nil {
                    try write(response, using: framer)
                }
                if await server.isShutdown {
                    if let activeGrantNamespace {
                        try await control.staleAuthoredAuthority(namespace: activeGrantNamespace)
                    }
                    return
                }
            }
        }
    }

    private static func firstRevision(_ request: JSONRPCRequest) -> MCPProtocolRevision? {
        switch request.method {
        case "initialize": .legacy
        case "server/discover": .modern
        default: nil
        }
    }

    private static func clientID(from request: JSONRPCRequest, revision: MCPProtocolRevision) -> String? {
        let value: JSONValue?
        switch revision {
        case .legacy:
            value = request.params?.objectValue?["clientInfo"]
        case .modern:
            value = request.metadata?.objectValue?["clientInfo"]
        }
        return value?.objectValue?["id"]?.stringValue ?? value?.objectValue?["name"]?.stringValue
    }

    private static func stableLedgerID(for clientID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in clientID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func write(_ response: JSONRPCResponse, using framer: JSONRPCFramer) throws {
        let payload = try framer.frame(JSONEncoder().encode(response))
        try FileHandle.standardOutput.write(contentsOf: payload)
    }

    private static func defaultSocketPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Allward/run/app.sock")
            .path
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

/// The process-local grant is pinned because the app's mode-0600 socket authenticates the sole v1 owner.
private struct OwnerSocketGrantAuthenticator: MCPGrantAuthenticating {
    let grantID: UUID
    let signature: Data

    func authenticate(_ grant: MCPGrant) async throws {
        guard grant.id == grantID, grant.signature == signature else {
            throw MCPAuthorizationError.invalidGrant("owner grant signature mismatch")
        }
    }
}
