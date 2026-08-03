import AllwardCore
import AllwardHerdr
import AllwardRemote
import AllwardSSH
import XCTest

@testable import AllwardPlatformMAS

final class HerdrOverExecChannelTests: XCTestCase {
    func testSnapshotDecodesASessionFromTheRealHerdrServer() async throws {
        let client = try Self.liveClient()
        let snapshot = try await client.snapshot(
            trigger: .explicitFocus,
            bound: .controlRequest
        )

        XCTAssertEqual(snapshot.version, "0.7.5")
        XCTAssertEqual(snapshot.protocolVersion, 17)
        let session = try XCTUnwrap(
            snapshot.workspaces.first(where: { $0.label == "allward" }),
            "the live herdr snapshot did not contain the allward session"
        )
        XCTAssertTrue(
            snapshot.panes.contains(where: { $0.workspaceID == session.workspaceID }),
            "the decoded session had no decoded panes"
        )
    }

    func testAgentsDecodesAnAgentFromTheRealHerdrServer() async throws {
        let client = try Self.liveClient()
        let agents = try await client.agents(bound: .controlRequest)

        let agent = try XCTUnwrap(agents.first, "the live herdr server returned no agents")
        XCTAssertFalse(agent.terminalID.isEmpty)
        XCTAssertFalse(agent.workspaceID.isEmpty)
        XCTAssertFalse(agent.paneID.isEmpty)
        XCTAssertNotEqual(agent.agentStatus, .unknown)
    }

    private static func liveClient() throws -> HerdrSocketClient {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ALLWARD_HERDR_TEST_HOST"], !host.isEmpty,
            let user = environment["ALLWARD_HERDR_TEST_USER"], !user.isEmpty,
            let key = environment["ALLWARD_HERDR_TEST_KEY"], !key.isEmpty
        else {
            throw XCTSkip(
                "set ALLWARD_HERDR_TEST_HOST, ALLWARD_HERDR_TEST_USER, and "
                    + "ALLWARD_HERDR_TEST_KEY to run the live herdr exec-channel tests"
            )
        }

        let alias = HostAlias("herdrTestHost")
        let directory = RemoteHostDirectory([
            RemoteHost(alias: alias, hostname: host, user: user, identityFile: key)
        ])
        let transport = RusshTransport(hosts: directory)
        let endpoint = HerdrEndpoint(host: alias, executionSite: .ssh)
        let executor = HerdrExecChannelExecutor(transport: transport)
        return HerdrSocketClient(
            endpoint: endpoint,
            executor: executor.executor(for: endpoint)
        )
    }
}
