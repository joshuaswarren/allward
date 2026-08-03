import AllwardCore
import Foundation
import XCTest

@testable import AllwardConfig

final class HostIdentityHygieneTests: XCTestCase {
    func testHostWriterRoundTripsIdentityPathWithoutPrivateKeyContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("allward-identity-hygiene-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("allward.toml")
        let identityPath = ProcessInfo.processInfo.environment["ALLWARD_SSH_TEST_PEM_KEY"]
            ?? "/Users/example/.ssh/id_rsa"
        let configuration = Configuration(
            hosts: [
                HostConfiguration(
                    alias: HostAlias("example"),
                    hostname: "example.test",
                    user: "tester",
                    identityFile: identityPath
                )
            ]
        )

        _ = try configuration.write(to: url)
        let emitted = try String(contentsOf: url, encoding: .utf8)
        let loaded = try Configuration.load(from: url)

        XCTAssertTrue(emitted.contains("identity-file"))
        XCTAssertTrue(emitted.contains(identityPath))
        XCTAssertFalse(emitted.contains("-----BEGIN"))
        XCTAssertFalse(emitted.contains("PRIVATE KEY"))
        XCTAssertEqual(loaded.hosts.first?.identityFile, identityPath)
    }
}
