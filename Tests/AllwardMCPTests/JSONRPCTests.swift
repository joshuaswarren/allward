import AllwardCore
import Foundation
import XCTest

@testable import AllwardMCP

final class JSONRPCTests: XCTestCase {
    func testLineDelimitedFramingIsDetectedAndLocked() throws {
        var framer = JSONRPCFramer()
        let first = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let messages = try framer.receive(first + Data("\n".utf8))

        XCTAssertEqual(framer.style, .lineDelimited)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(JSONRPCRequest.self, from: messages[0]).method, "ping")
        XCTAssertEqual(try framer.frame(messages[0]), messages[0] + Data("\n".utf8))
    }

    func testContentLengthFramingHandlesFragmentedInput() throws {
        var framer = JSONRPCFramer()
        let body = Data(#"{"jsonrpc":"2.0","id":"request-1","method":"ping"}"#.utf8)
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)

        XCTAssertTrue(try framer.receive(header.prefix(12)).isEmpty)
        let messages = try framer.receive(Data(header.dropFirst(12)) + body)

        XCTAssertEqual(framer.style, .contentLength)
        XCTAssertEqual(messages, [body])
        XCTAssertEqual(try framer.frame(body), header + body)
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let server = MCPServer(toolProvider: EmptyToolProvider())
        _ = await server.handle(JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolRevision.legacy.rawValue),
                "clientInfo": .object(["name": .string("test-client")])
            ])
        ))
        _ = await server.handle(JSONRPCRequest(method: "notifications/initialized"))
        let request = JSONRPCRequest(id: .integer(7), method: "not/a/method")

        let response = await server.handle(request)

        XCTAssertEqual(response.id, .integer(7))
        XCTAssertEqual(response.error?.code, JSONRPCErrorCode.methodNotFound.rawValue)
    }

    func testToolCallReturnsTypedOutOfScopeError() async throws {
        let server = MCPServer(toolProvider: ScopeRejectingToolProvider())
        _ = await server.handle(JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolRevision.legacy.rawValue),
                "clientInfo": .object(["name": .string("test-client")])
            ])
        ))
        _ = await server.handle(JSONRPCRequest(method: "notifications/initialized"))
        let response = await server.handle(JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("allward_screen"),
                "arguments": .object([:])
            ])
        ))

        XCTAssertEqual(response.error?.code, -32_001)
        XCTAssertEqual(response.error?.data?.objectValue?["type"], .string("target_out_of_scope"))
    }

    func testIdempotentReplayReturnsRecordedResultWithoutRedispatch() async throws {
        let ledger = MCPMutationLedger(maximumEntries: 32)
        let dispatchCounter = DispatchCounter()
        let key = MCPMutationKey(
            clientID: "client-a",
            grantNamespace: "namespace-a",
            invocationID: "invocation-a"
        )
        let descriptor = MCPMutationDescriptor(
            operation: "allward_send_text",
            canonicalArguments: #"{"pane_id":"00000000-0000-0000-0000-000000000001","text":"pwd"}"#,
            exactTarget: "room:00000000-0000-0000-0000-000000000002/pane:00000000-0000-0000-0000-000000000001"
        )

        let first = try await ledger.perform(key: key, descriptor: descriptor) {
            await dispatchCounter.increment()
            return .object(["accepted": .bool(true)])
        }
        let replay = try await ledger.perform(key: key, descriptor: descriptor) {
            await dispatchCounter.increment()
            return .object(["accepted": .bool(false)])
        }

        let dispatchCount = await dispatchCounter.value
        XCTAssertEqual(first, .object(["accepted": .bool(true)]))
        XCTAssertEqual(replay, first)
        XCTAssertEqual(dispatchCount, 1)
    }

    func testEveryToolPublishesAnObjectSchema() throws {
        let definitions = AllwardTools.definitions
        XCTAssertEqual(definitions.count, 20)
        XCTAssertEqual(Set(definitions.map(\.name)).count, definitions.count)
        for definition in definitions {
            XCTAssertEqual(definition.inputSchema.objectValue?["type"], .string("object"))
            XCTAssertNotNil(definition.inputSchema.objectValue?["properties"]?.objectValue)
        }
    }

    func testOutOfScopeTargetIsRejectedBeforeDispatch() async throws {
        let allowedRoom = RoomID(rawValue: try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deniedRoom = RoomID(rawValue: try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        ))
        let now = Date(timeIntervalSince1970: 1_000)
        let binding = MCPConnectionBinding(
            serverInstanceAudience: "server-a",
            protocolRevision: .legacy,
            transport: .stdioLineDelimited,
            launcherNonce: "launcher-a",
            channelNonce: "channel-a",
            presenterID: "presenter-a"
        )
        let grant = MCPGrant(
            id: UUID(),
            clientID: "client-a",
            invocationNamespace: "namespace-a",
            serverInstanceAudience: binding.serverInstanceAudience,
            protocolRevision: binding.protocolRevision,
            transport: binding.transport,
            launcherNonce: binding.launcherNonce,
            channelNonce: binding.channelNonce,
            presenterID: binding.presenterID,
            capabilities: [.readScreen],
            targetScope: MCPGrantTargetScope(rooms: [allowedRoom]),
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60),
            signature: Data([1])
        )
        let authorizer = CallerCapabilityAuthorizer(
            grant: grant,
            binding: binding,
            authenticator: AcceptingAuthenticator(),
            clock: FixedClock(now)
        )

        do {
            _ = try await authorizer.validate(capability: .readScreen, target: Target(room: deniedRoom))
            XCTFail("Expected target_out_of_scope")
        } catch let error as MCPAuthorizationError {
            guard case .targetOutOfScope = error else {
                return XCTFail("Unexpected authorization error: \(error)")
            }
        }
    }
}

private struct AcceptingAuthenticator: MCPGrantAuthenticating {
    func authenticate(_ grant: MCPGrant) async throws {}
}

private struct EmptyToolProvider: MCPToolProviding {
    func listTools() async -> [MCPToolDefinition] { [] }

    func callTool(
        name: String,
        arguments: JSONValue,
        context: MCPProtocolClientContext
    ) async throws -> JSONValue {
        throw MCPToolError.unknownTool(name)
    }
}

private struct ScopeRejectingToolProvider: MCPToolProviding {
    func listTools() async -> [MCPToolDefinition] { [] }

    func callTool(
        name: String,
        arguments: JSONValue,
        context: MCPProtocolClientContext
    ) async throws -> JSONValue {
        guard let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000003") else {
            throw MCPToolError.invalidArguments("Invalid test identifier")
        }
        throw MCPAuthorizationError.targetOutOfScope(Target(room: RoomID(rawValue: identifier)))
    }
}

private actor DispatchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
