import AllwardCore
import Foundation
import XCTest

@testable import AllwardSSH

/// Trust on first use is only worth having if the pin outlives the process. These
/// exercise the store directly, since the property that matters is what survives a
/// relaunch, and a relaunch is a second instance reading the same file.
final class DurableHostTrustTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allward-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(
        onMismatch: @escaping @Sendable (HostAlias, SSHHostKey, String) -> Void = { _, _, _ in }
    ) -> DurableHostTrust {
        DurableHostTrust(
            url: DurableHostTrust.defaultURL(inContainer: directory), onMismatch: onMismatch)
    }

    private func key(_ fingerprint: String) -> SSHHostKey {
        SSHHostKey(algorithm: "ssh-ed25519", fingerprint: fingerprint, blob: [1, 2, 3])
    }

    func testFirstUseIsAcceptedAndPinned() {
        let trust = store()
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        XCTAssertEqual(trust.pinnedFingerprint(for: HostAlias("alpha")), "SHA256:aaa")
    }

    func testTheSameKeyIsAcceptedAgain() {
        let trust = store()
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
    }

    /// The whole point. A changed key is refused, and the mismatch is reported with
    /// the fingerprint that was expected so the user can compare them.
    func testAChangedKeyIsRefusedAndReported() {
        // The callback runs on whatever thread refused the key, so the recording box
        // is locked rather than a captured var.
        let reported = MismatchRecorder()
        let trust = store { host, presented, expected in
            reported.record(host: host, presented: presented.fingerprint, expected: expected)
        }
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        XCTAssertFalse(trust.accepts(key("SHA256:bbb"), for: HostAlias("alpha")))
        XCTAssertEqual(reported.host, HostAlias("alpha"))
        XCTAssertEqual(reported.presented, "SHA256:bbb")
        XCTAssertEqual(reported.expected, "SHA256:aaa")
    }

    /// A pin that does not survive relaunch re-trusts a changed key on next launch,
    /// which is exactly what an in-memory store got wrong.
    func testAPinSurvivesANewInstance() {
        XCTAssertTrue(store().accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        let relaunched = store()
        XCTAssertEqual(relaunched.pinnedFingerprint(for: HostAlias("alpha")), "SHA256:aaa")
        XCTAssertFalse(relaunched.accepts(key("SHA256:bbb"), for: HostAlias("alpha")))
    }

    /// Forgetting is how a user accepts a key that legitimately changed, after being
    /// shown the mismatch.
    func testForgettingAHostAllowsANewFirstUse() {
        let trust = store()
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        trust.forget(HostAlias("alpha"))
        XCTAssertNil(trust.pinnedFingerprint(for: HostAlias("alpha")))
        XCTAssertTrue(trust.accepts(key("SHA256:bbb"), for: HostAlias("alpha")))
    }

    func testHostsArePinnedIndependently() {
        let trust = store()
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        XCTAssertTrue(trust.accepts(key("SHA256:bbb"), for: HostAlias("beta")))
        XCTAssertFalse(trust.accepts(key("SHA256:bbb"), for: HostAlias("alpha")))
    }

    /// A corrupt file must not silently discard every pin, because that would
    /// re-trust every host. It reads as no pins, so the next connection is a first
    /// use the user sees rather than a silent acceptance of a changed key.
    func testACorruptFileDoesNotSilentlyTrustEveryone() throws {
        let url = DurableHostTrust.defaultURL(inContainer: directory)
        try Data("not json".utf8).write(to: url)
        let trust = store()
        XCTAssertNil(trust.pinnedFingerprint(for: HostAlias("alpha")))
        XCTAssertTrue(trust.accepts(key("SHA256:aaa"), for: HostAlias("alpha")))
        XCTAssertFalse(trust.accepts(key("SHA256:ccc"), for: HostAlias("alpha")))
    }
}

/// Collects one mismatch report from whichever thread produced it.
private final class MismatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (host: HostAlias, presented: String, expected: String)?

    func record(host: HostAlias, presented: String, expected: String) {
        lock.lock()
        value = (host, presented, expected)
        lock.unlock()
    }

    var host: HostAlias? { read()?.host }
    var presented: String? { read()?.presented }
    var expected: String? { read()?.expected }

    private func read() -> (host: HostAlias, presented: String, expected: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
