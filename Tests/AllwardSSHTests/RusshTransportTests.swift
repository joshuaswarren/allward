import AllwardCore
import AllwardRemote
import XCTest

@testable import AllwardSSH

/// Exercises the russh transport against a real SSH server.
///
/// A transport that compiles proves nothing, so these open an actual session and
/// read actual bytes. They need a server, which CI does not have, so they read it
/// from the environment and skip when it is absent rather than failing:
///
/// ```sh
/// ALLWARD_SSH_TEST_HOST=127.0.0.1 \
/// ALLWARD_SSH_TEST_USER="$(whoami)" \
/// ALLWARD_SSH_TEST_KEY="$HOME/.ssh/id_rsa" \
///     swift test --filter RusshTransportTests
/// ```
///
/// Skipping is honest here and a default host would not be: pointing at a guessed
/// server would either fail for the wrong reason or quietly test nothing.
final class RusshTransportTests: XCTestCase {
    private struct Target {
        var host: String
        var user: String
        var keyPath: String
    }

    private func target() throws -> Target {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ALLWARD_SSH_TEST_HOST"],
            let user = environment["ALLWARD_SSH_TEST_USER"],
            let key = environment["ALLWARD_SSH_TEST_KEY"]
        else {
            throw XCTSkip(
                "set ALLWARD_SSH_TEST_HOST, ALLWARD_SSH_TEST_USER, and ALLWARD_SSH_TEST_KEY "
                    + "to run the live SSH tests")
        }
        return Target(host: host, user: user, keyPath: key)
    }

    private func transport(for target: Target, trust: any SSHHostTrust) -> RusshTransport {
        let directory = RemoteHostDirectory([
            RemoteHost(
                alias: HostAlias("test"),
                hostname: target.host,
                user: target.user,
                identityFile: target.keyPath)
        ])
        return RusshTransport(hosts: directory, hostTrust: trust)
    }

    /// Reads until the marker appears, the channel exits, or the deadline passes.
    private func collect(
        from channel: any RemoteChannel,
        until marker: String,
        seconds: Double = 20
    ) async -> (text: String, exited: Bool) {
        var text = ""
        var exited = false
        let deadline = Date().addingTimeInterval(seconds)
        for await event in channel.events {
            switch event {
            case let .bytes(slice):
                text += String(decoding: slice, as: UTF8.self)
                if text.contains(marker) { return (text, exited) }
            case .exited:
                exited = true
                return (text, exited)
            case let .failed(error):
                return ("failed: \(error)", exited)
            case .state:
                break
            }
            if Date() > deadline { break }
        }
        return (text, exited)
    }

    /// The capability that decided decision 40. A mostly-RSA key inventory is
    /// useless to a transport that cannot authenticate with an RSA key.
    func testOpensAPTYSessionAndRunsACommandWithAnRSAKey() async throws {
        let target = try target()
        let transport = transport(for: target, trust: TrustOnFirstUseHostTrust())
        let channel = try await transport.open(
            .ssh(HostAlias("test"), command: ["echo", "ALLWARD_SWIFT_SSH_OK"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect
        )
        let result = await collect(from: channel, until: "ALLWARD_SWIFT_SSH_OK")
        channel.close()
        XCTAssertTrue(
            result.text.contains("ALLWARD_SWIFT_SSH_OK"),
            "expected the command's output, got: \(result.text)")
    }

    /// A login shell with a PTY is what a pane actually opens, so it is tested
    /// separately from `exec`: only the former requests a shell.
    func testOpensALoginShellAndAcceptsInput() async throws {
        let target = try target()
        let transport = transport(for: target, trust: TrustOnFirstUseHostTrust())
        let channel = try await transport.open(
            .ssh(HostAlias("test")),
            geometry: (columns: 80, rows: 24),
            bound: .connect
        )
        channel.write(Array("echo ALLWARD_SHELL_OK\n".utf8))
        let result = await collect(from: channel, until: "ALLWARD_SHELL_OK")
        channel.resize(columns: 120, rows: 40)
        channel.close()
        XCTAssertTrue(
            result.text.contains("ALLWARD_SHELL_OK"),
            "expected shell output, got: \(result.text)")
    }

    /// Host trust belongs to Allward, not to the protocol library. A refusal must
    /// stop the session rather than be advisory.
    func testARejectedHostKeyRefusesTheSession() async throws {
        let target = try target()
        let transport = transport(for: target, trust: RefusingHostTrust())
        do {
            let channel = try await transport.open(
                .ssh(HostAlias("test"), command: ["echo", "should not run"]),
                geometry: (columns: 80, rows: 24),
                bound: .connect
            )
            let result = await collect(from: channel, until: "should not run", seconds: 8)
            channel.close()
            XCTAssertFalse(
                result.text.contains("should not run"),
                "a refused host key must not produce a working session")
        } catch {
            // Refusal surfacing as a thrown open is the other acceptable shape.
        }
    }

    /// An unconfigured alias must fail with a configured-host message rather than
    /// silently consulting `~/.ssh/config`, which a sandboxed product cannot read.
    func testAnUnconfiguredHostFailsWithoutConsultingSSHConfig() async throws {
        let transport = RusshTransport(hosts: RemoteHostDirectory())
        do {
            _ = try await transport.open(
                .ssh(HostAlias("definitely-not-configured")),
                geometry: (columns: 80, rows: 24),
                bound: .connect)
            XCTFail("an unconfigured host must not open")
        } catch let error as AllwardError {
            XCTAssertEqual(error.domain, .transport)
            XCTAssertTrue(error.cause.contains("definitely-not-configured"))
        }
    }

    func testSupportsOnlySSHDestinationsWithAHost() {
        let transport = RusshTransport(hosts: RemoteHostDirectory())
        XCTAssertTrue(transport.supports(RemoteDestination.ssh(HostAlias("anything"))))
        XCTAssertFalse(transport.supports(RemoteDestination.localShell()))
    }
}

private struct RefusingHostTrust: SSHHostTrust {
    func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool { false }
}
