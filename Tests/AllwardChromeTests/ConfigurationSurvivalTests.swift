import AllwardConfig
import XCTest

@testable import AllwardChrome

/// A configuration file the app cannot read is still the user's file.
final class ConfigurationSurvivalTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allward-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUnreadableConfigurationIsReportedAndLeftExactlyAsWritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("allward.toml")
        let original = "[terminal]\nfont-size = \"this is not a number\"\nnonsense = [{a = 1}]\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let loaded = await AllwardAppDelegate.loadOrSeedConfiguration(at: url)

        XCTAssertNotNil(loaded.failure, "A file that cannot be read must be reported.")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), original,
            "The file must be byte-for-byte untouched; overwriting it destroys the settings.")
    }

    func testMissingConfigurationIsSeeded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("allward.toml")

        let loaded = await AllwardAppDelegate.loadOrSeedConfiguration(at: url)

        XCTAssertNil(loaded.failure, "A first run is not a failure.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "A missing file is seeded so the first run lands in a usable app.")
    }
}
