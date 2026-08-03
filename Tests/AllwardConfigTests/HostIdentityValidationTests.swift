import AllwardCore
import XCTest

@testable import AllwardConfig

/// Allward writes `allward.toml` back on every settings change, so a private key
/// pasted where a path belongs would be persisted to disk in plain text by us.
/// Load-time refusal is the last point where that is preventable.
final class HostIdentityValidationTests: XCTestCase {
    private func configuration(identityFile: String?) -> Configuration {
        var configuration = Configuration()
        configuration.hosts = [
            HostConfiguration(
                alias: HostAlias("box"), hostname: "example.invalid", user: "someone",
                port: 22, identityFile: identityFile)
        ]
        return configuration
    }

    func testAPathIsAccepted() throws {
        XCTAssertNoThrow(try configuration(identityFile: "~/.ssh/id_ed25519").validate())
    }

    func testNoIdentityIsAccepted() throws {
        XCTAssertNoThrow(try configuration(identityFile: nil).validate())
    }

    /// The realistic accident: someone pastes the key instead of its path.
    func testAPastedPrivateKeyIsRefused() {
        let pem = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAA
            -----END OPENSSH PRIVATE KEY-----
            """
        XCTAssertThrowsError(try configuration(identityFile: pem).validate())
    }

    /// A single-line paste still carries the marker, so the newline check alone
    /// would not catch it.
    func testASingleLineKeyMarkerIsRefused() {
        XCTAssertThrowsError(
            try configuration(identityFile: "-----BEGIN RSA PRIVATE KEY----- AAAA").validate())
    }

    /// Any multi-line value is not a path, whatever it contains.
    func testAMultiLineValueIsRefused() {
        XCTAssertThrowsError(try configuration(identityFile: "~/.ssh/a\n~/.ssh/b").validate())
    }

    /// An empty string is a different mistake from an absent key, and silently
    /// treating it as "no identity" would hide a truncated edit.
    func testAnEmptyIdentityIsRefused() {
        XCTAssertThrowsError(try configuration(identityFile: "").validate())
    }
}
