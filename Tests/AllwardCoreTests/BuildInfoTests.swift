import Foundation
import XCTest

@testable import AllwardCore

/// The About panel exists so a test build can be told from the previous one, so the
/// case that matters most is the one where nothing is known: a blank panel would
/// read as a release rather than as an unidentified binary.
final class BuildInfoTests: XCTestCase {
    private func info(
        commit: String? = "a1b2c3d4e5f6",
        isDirty: Bool = false,
        builtAt: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        configuration: String? = "release",
        product: String? = "Developer ID"
    ) -> BuildInfo {
        BuildInfo(
            commit: commit, isDirty: isDirty, builtAt: builtAt,
            configuration: configuration, product: product, version: "0.1.0")
    }

    func testSummaryCarriesTheCommitForComparison() {
        XCTAssertEqual(info().shortSummary, "0.1.0 (a1b2c3d4e5f6)")
    }

    /// A synced test build of work in progress is the normal case, so "modified" is
    /// stated rather than hidden: the commit alone would name a revision that does
    /// not describe what was compiled.
    func testAModifiedTreeIsSaidOutLoud() {
        XCTAssertEqual(info(isDirty: true).shortSummary, "0.1.0 (a1b2c3d4e5f6, modified)")
        XCTAssertTrue(info(isDirty: true).plainText.contains("(modified)"))
    }

    func testAnUnknownBuildSaysSoRatherThanLookingLikeARelease() {
        let unknown = info(commit: nil, builtAt: nil, configuration: nil, product: nil)
        XCTAssertTrue(unknown.isUnknown)
        XCTAssertEqual(unknown.shortSummary, "0.1.0 (unknown build)")
        XCTAssertTrue(unknown.plainText.contains("Commit: unknown"))
        XCTAssertTrue(unknown.plainText.contains("Built: unknown"))
    }

    func testKnownBuildIsNotReportedAsUnknown() {
        XCTAssertFalse(info().isUnknown)
    }

    /// Both products are called Allward and behave differently, so which one this is
    /// belongs in the panel.
    func testDetailsNameTheProductAndConfiguration() {
        let rows = Dictionary(uniqueKeysWithValues: info().details.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Product"], "Developer ID")
        XCTAssertEqual(rows["Configuration"], "release")
        XCTAssertEqual(rows["Commit"], "a1b2c3d4e5f6")
    }

    /// The scripts write these keys and this type reads them. A rename on one side
    /// only would silently produce an unknown build, so the contract is pinned.
    func testInfoPlistKeysAreTheOnesTheScriptsWrite() {
        XCTAssertEqual(BuildInfo.Key.commit, "AllwardBuildCommit")
        XCTAssertEqual(BuildInfo.Key.dirty, "AllwardBuildDirty")
        XCTAssertEqual(BuildInfo.Key.date, "AllwardBuildDate")
        XCTAssertEqual(BuildInfo.Key.configuration, "AllwardBuildConfiguration")
        XCTAssertEqual(BuildInfo.Key.product, "AllwardBuildProduct")
    }

    /// `build-info.sh` prints `unknown` when it has no source. Treating that literal
    /// as a value would put the word "unknown" where a commit belongs and report the
    /// build as identified.
    func testTheLiteralUnknownIsTreatedAsAbsent() {
        let bundle = StubBundle([
            BuildInfo.Key.commit: "unknown",
            BuildInfo.Key.dirty: "false",
            "CFBundleShortVersionString": "0.1.0",
        ])
        let parsed = BuildInfo(bundle: bundle)
        XCTAssertNil(parsed.commit)
        XCTAssertTrue(parsed.isUnknown)
    }

    func testReadsWhatTheScriptsWrite() {
        let bundle = StubBundle([
            BuildInfo.Key.commit: "0123456789ab",
            BuildInfo.Key.dirty: "true",
            BuildInfo.Key.date: "2026-08-02T20:15:03Z",
            BuildInfo.Key.configuration: "debug",
            BuildInfo.Key.product: "Mac App Store",
            "CFBundleShortVersionString": "0.1.0",
        ])
        let parsed = BuildInfo(bundle: bundle)
        XCTAssertEqual(parsed.commit, "0123456789ab")
        XCTAssertTrue(parsed.isDirty)
        XCTAssertEqual(parsed.product, "Mac App Store")
        XCTAssertEqual(parsed.configuration, "debug")
        XCTAssertNotNil(parsed.builtAt)
        XCTAssertFalse(parsed.isUnknown)
    }
}

/// Answers Info.plist lookups from a dictionary, so the reader can be tested
/// without assembling a bundle on disk.
private final class StubBundle: Bundle {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
}
