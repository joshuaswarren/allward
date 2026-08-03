import AllwardCore
import AllwardRemote
import Foundation
import XCTest

@testable import AllwardSSH

/// Exercises the facade cells that a real SSH endpoint can expose today. Cells
/// outside the facade remain explicit skips so the receipt cannot imply coverage.
final class SSHLifecycleTests: XCTestCase {
    private enum StopCondition: Sendable {
        case bytes(String)
        case state(ConnectionState)
        case exited
        case failed
    }

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
                    + "to run the live SSH lifecycle cells")
        }
        return Target(host: host, user: user, keyPath: key)
    }

    private func transport(for target: Target, trust: any SSHHostTrust = TrustOnFirstUseHostTrust())
        -> RusshTransport
    {
        let directory = RemoteHostDirectory([
            RemoteHost(
                alias: HostAlias("test"),
                hostname: target.host,
                user: target.user,
                identityFile: target.keyPath)
        ])
        return RusshTransport(hosts: directory, hostTrust: trust)
    }

    private func collect(
        from channel: any RemoteChannel,
        until condition: StopCondition,
        seconds: Double = 20
    ) async -> [RemoteEvent] {
        await withTaskGroup(of: [RemoteEvent].self) { group in
            group.addTask {
                var events: [RemoteEvent] = []
                for await event in channel.events {
                    events.append(event)
                    if Self.shouldStop(events, condition: condition) { return events }
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private static func shouldStop(_ events: [RemoteEvent], condition: StopCondition) -> Bool {
        switch condition {
        case let .bytes(marker): return bytes(in: events).contains(marker)
        case let .state(state): return hasState(state, in: events)
        case .exited: return events.contains { if case .exited = $0 { true } else { false } }
        case .failed: return events.contains { if case .failed = $0 { true } else { false } }
        }
    }

    private static func hasState(_ state: ConnectionState, in events: [RemoteEvent]) -> Bool {
        events.contains { event in
            guard case let .state(actual, _) = event else { return false }
            return actual == state
        }
    }

    private static func bytes(in events: [RemoteEvent]) -> String {
        events.reduce(into: "") { result, event in
            if case let .bytes(slice) = event {
                result += String(decoding: slice, as: UTF8.self)
            }
        }
    }

    func testConnectCellReportsConnecting() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test"), command: ["true"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        let events = await collect(from: channel, until: .exited)
        channel.close()
        XCTAssertTrue(Self.hasState(.connecting, in: events), "connect must report connecting")
    }

    func testAuthenticateCellReportsAuthenticating() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test"), command: ["true"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        let events = await collect(from: channel, until: .state(.ready))
        channel.close()
        XCTAssertTrue(
            Self.hasState(.authenticating, in: events),
            "authentication must be visible before ready")
    }

    func testLiveRemotePTYCarriesInputAndOutput() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test")),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        channel.write(Array("printf 'ALLWARD_'$(printf 'PTY_OK')'\\n'\n".utf8))
        let events = await collect(from: channel, until: .bytes("ALLWARD_PTY_OK"))
        channel.close()
        XCTAssertTrue(Self.bytes(in: events).contains("ALLWARD_PTY_OK"))
        XCTAssertTrue(Self.hasState(.ready, in: events), "a PTY must become ready")
    }

    func testControlCellPublishesPTYResize() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test")),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        channel.resize(columns: 120, rows: 40)
        channel.write(Array("stty size; printf '\\nALLWARD_'$(printf 'RESIZE_OK')'\\n'\n".utf8))
        let events = await collect(from: channel, until: .bytes("ALLWARD_RESIZE_OK"))
        channel.close()
        let output = Self.bytes(in: events)
        XCTAssertTrue(output.contains("40 120"), "resize must reach the remote PTY: \(output)")
    }

    func testExitCodeCellReportsNonZeroStatus() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test"), command: ["false"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        let events = await collect(from: channel, until: .exited)
        let exitCode = events.compactMap { event -> Int32? in
            guard case let .exited(code) = event else { return nil }
            return code
        }.first
        XCTAssertEqual(exitCode, 1)
    }

    func testTrustCellRefusesHostKey() async throws {
        let target = try target()
        let trust = RefusingHostTrust()
        do {
            let channel = try await transport(for: target, trust: trust).open(
                .ssh(HostAlias("test"), command: ["echo", "ALLWARD_TRUST_MUST_NOT_RUN"]),
                geometry: (columns: 80, rows: 24),
                bound: .connect)
            let events = await collect(from: channel, until: .failed, seconds: 8)
            channel.close()
            XCTAssertTrue(
                events.contains { if case .failed = $0 { true } else { false } },
                "a refused host key must fail the channel")
            XCTAssertFalse(Self.bytes(in: events).contains("ALLWARD_TRUST_MUST_NOT_RUN"))
        } catch {
            XCTAssertTrue(error is AllwardError, "trust denial must surface as a transport error")
        }
        XCTAssertTrue(trust.wasAsked, "the refused host key must reach the injected trust policy")
    }

    func testCancelCellCancelsAnInFlightOpen() async throws {
        let target = try target()
        let trust = BlockingHostTrust()
        let transport = transport(for: target, trust: trust)
        let completion = CompletionFlag()
        let task = Task {
            defer { completion.mark() }
            let channel = try await transport.open(
                .ssh(HostAlias("test")),
                geometry: (columns: 80, rows: 24),
                bound: .connect)
            channel.close()
        }
        XCTAssertTrue(trust.waitUntilEntered(), "open should reach host trust while in flight")
        task.cancel()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let finished = completion.value
        trust.release()
        _ = await task.result
        XCTAssertTrue(
            finished,
            "cancelling an in-flight open must terminate it within three seconds")
    }

    func testCloseCellReportsExplicitClosedStateWithoutFailure() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test")),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        channel.close()
        let events = await collect(from: channel, until: .state(.closed(.explicit)), seconds: 8)
        XCTAssertTrue(Self.hasState(.closed(.explicit), in: events))
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
    }

    func testDisconnectCellReportsRemoteExitWithoutFailure() async throws {
        let target = try target()
        let channel = try await transport(for: target).open(
            .ssh(HostAlias("test"), command: ["sh", "-c", "exit 7"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect)
        let events = await collect(from: channel, until: .exited)
        XCTAssertTrue(events.contains { if case .exited = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
    }

    func testForwardCellIsExplicitlyUnproven() throws {
        throw XCTSkip("RemoteTransport exposes no forwarding operation")
    }

    func testReconnectCellIsExplicitlyUnproven() throws {
        throw XCTSkip("RemoteTransport has no reconnect or connection-supervisor operation")
    }

    func testGenerationFenceCellIsExplicitlyUnproven() throws {
        throw XCTSkip("RemoteTransport exposes no operation or generation token for stale callbacks")
    }
}
private final class RefusingHostTrust: SSHHostTrust, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    var wasAsked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool {
        lock.lock()
        asked = true
        lock.unlock()
        return false
    }
}

private final class BlockingHostTrust: SSHHostTrust, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return true
    }

    func waitUntilEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !entered {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func mark() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}
