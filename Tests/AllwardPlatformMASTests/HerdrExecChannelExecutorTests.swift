import AllwardCore
import AllwardHerdr
import AllwardRemote
import AllwardSSH
import XCTest

@testable import AllwardPlatformMAS

/// The sandboxed product runs herdr commands as SSH exec channels. These prove the
/// translation and the refusals without needing a herdr server, plus one live case
/// that runs a real command over a real channel.
final class HerdrExecChannelExecutorTests: XCTestCase {
    /// The transport prefix must come off, or the sandboxed product would try to
    /// run `ssh` as the remote command.
    func testStripsTheTransportPrefixFromTheArgv() {
        let endpoint = HerdrEndpoint(host: HostAlias("alpha"), executionSite: .ssh)
        let argv = endpoint.argv(for: ["list", "--json"])
        XCTAssertEqual(argv, ["ssh", "alpha", "herdr", "list", "--json"])
        XCTAssertEqual(endpoint.remoteCommand(from: argv), ["herdr", "list", "--json"])
    }

    /// A mismatch must be refused rather than executed. Silently running an argv of
    /// an unexpected shape is how a command ends up pointed at the wrong host.
    func testRefusesAnArgvItDidNotProduce() {
        let endpoint = HerdrEndpoint(host: HostAlias("alpha"), executionSite: .ssh)
        XCTAssertNil(endpoint.remoteCommand(from: ["ssh", "beta", "herdr", "list"]))
        XCTAssertNil(endpoint.remoteCommand(from: ["herdr", "list"]))
        XCTAssertNil(endpoint.remoteCommand(from: []))
    }

    func testLocalSiteKeepsItsOwnShape() {
        let endpoint = HerdrEndpoint(host: HostAlias("alpha"), executionSite: .local)
        XCTAssertEqual(endpoint.remoteCommand(from: ["herdr", "list"]), ["herdr", "list"])
        XCTAssertNil(endpoint.remoteCommand(from: ["ssh", "alpha", "herdr"]))
    }

    /// `HerdrExecutionSite.local` has no meaning in a sandboxed product, so the
    /// executor refuses it instead of translating it into something that works.
    func testRefusesALocalExecutionSite() async {
        let executor = HerdrExecChannelExecutor(
            transport: RusshTransport(hosts: RemoteHostDirectory()))
        let endpoint = HerdrEndpoint(host: HostAlias("alpha"), executionSite: .local)
        do {
            _ = try await executor.executor(for: endpoint)(["herdr", "list"])
            XCTFail("a local execution site must be refused")
        } catch let error as AllwardError {
            XCTAssertEqual(error.domain, .adapter)
            XCTAssertTrue(error.cause.contains("no local herdr"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The whole point of phase 4: a command runs on the far side with no process
    /// launched locally. `herdr` is not installed on the test host, so this runs a
    /// command that is, and asserts the exec channel carried its output.
    func testRunsARemoteCommandOverAnExecChannel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ALLWARD_SSH_TEST_HOST"],
            let user = environment["ALLWARD_SSH_TEST_USER"],
            let key = environment["ALLWARD_SSH_TEST_KEY"]
        else {
            throw XCTSkip(
                "set ALLWARD_SSH_TEST_HOST, ALLWARD_SSH_TEST_USER, and ALLWARD_SSH_TEST_KEY "
                    + "to run the live exec-channel test")
        }
        let alias = HostAlias("execHost")
        let directory = RemoteHostDirectory([
            RemoteHost(alias: alias, hostname: host, user: user, identityFile: key)
        ])
        let transport = RusshTransport(hosts: directory)
        let channel = try await transport.open(
            .ssh(alias, command: ["echo", "ALLWARD_EXEC_CHANNEL_OK"]),
            geometry: (columns: 200, rows: 50),
            bound: .controlRequest
        )
        var collected = Data()
        for await event in channel.events {
            if case let .bytes(slice) = event { collected.append(contentsOf: slice) }
            if case .exited = event { break }
            if String(decoding: collected, as: UTF8.self).contains("ALLWARD_EXEC_CHANNEL_OK") {
                break
            }
        }
        channel.close()
        XCTAssertTrue(
            String(decoding: collected, as: UTF8.self).contains("ALLWARD_EXEC_CHANNEL_OK"),
            "the exec channel carried no output")
    }
}
