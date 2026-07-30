import Foundation
import XCTest
import AllwardCore
import AllwardRooms

@testable import AllwardConfig

final class AllwardConfigTests: XCTestCase {
  func testTOMLRoundTripPreservesEverySupportedShape() throws {
    let source = #"""
    title = "Allward"
    literal = 'raw\\value'
    multiline = """
    first line
    second line
    """
    integer = -42
    float = 6.25e2
    enabled = true
    values = [1, 2, 3]
    nested = [["a", "b"], ["c"]]

    [terminal]
    font = "Berkeley Mono"

    [terminal.cursor]
    shape = "beam"
    blink = false

    [[rooms]]
    name = "Personal"
    hosts = ["laptop", "studio"]

    [[rooms]]
    name = "Work"
    hosts = []
    """#

    let parsed = try TOMLDocument.parse(source)
    let written = parsed.serialized()
    let reparsed = try TOMLDocument.parse(written)

    XCTAssertEqual(reparsed, parsed)
    XCTAssertEqual(parsed.value(at: ["multiline"]), .string("first line\nsecond line\n"))
    XCTAssertEqual(parsed.value(at: ["terminal", "cursor", "blink"]), .boolean(false))
    guard case let .array(rooms)? = parsed.value(at: ["rooms"]) else {
      return XCTFail("rooms was not an array of tables")
    }
    XCTAssertEqual(rooms.count, 2)
  }

  func testMultilineStringEndingInQuotesRoundTrips() throws {
    let document = TOMLDocument(root: ["value": .string("first\nsecond\"\"")])

    let reparsed = try TOMLDocument.parse(document.serialized())

    XCTAssertEqual(reparsed, document)
  }

  func testTOMLWriterOrderIsStable() throws {
    let parsed = try TOMLDocument.parse("z = 1\na = 2\n[middle]\ny = 3\nb = 4\n")
    let first = parsed.serialized()
    let second = try TOMLDocument.parse(first).serialized()

    XCTAssertEqual(first, second)
    XCTAssertLessThan(try XCTUnwrap(first.range(of: "a = 2")?.lowerBound),
                      try XCTUnwrap(first.range(of: "z = 1")?.lowerBound))
    XCTAssertLessThan(try XCTUnwrap(first.range(of: "b = 4")?.lowerBound),
                      try XCTUnwrap(first.range(of: "y = 3")?.lowerBound))
  }

  func testValidationNamesExactOffendingKey() {
    var configuration = Configuration.default
    configuration.terminal.fontSize = 0

    XCTAssertThrowsError(try configuration.validate()) { error in
      guard let allwardError = error as? AllwardError else {
        return XCTFail("Expected AllwardError, got \(error)")
      }
      XCTAssertEqual(allwardError.operation, "terminal.font-size")
    }
  }

  func testExplicitlyEmptyRoomsFailsValidation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("allward.toml")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("rooms = []\n".utf8).write(to: url)

    XCTAssertThrowsError(try Configuration.load(from: url)) { error in
      XCTAssertEqual((error as? AllwardError)?.operation, "rooms")
    }
  }

  func testAtomicWriteAdvancesGenerationAndReloadsTypedValues() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("allward.toml")
    defer { try? FileManager.default.removeItem(at: directory) }
    var configuration = Configuration.default
    configuration.terminal.fontFamily = "Berkeley Mono"
    configuration.boardPresentation = .compact

    let written = try configuration.write(to: url)
    let loaded = try Configuration.load(from: url)

    XCTAssertEqual(written.generation, configuration.generation.next)
    XCTAssertEqual(loaded.terminal.fontFamily, "Berkeley Mono")
    XCTAssertEqual(loaded.boardPresentation, .compact)
    XCTAssertEqual(loaded.rooms, configuration.rooms)
  }

  func testAtomicWriteRejectsAnExternalEdit() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("allward.toml")
    defer { try? FileManager.default.removeItem(at: directory) }
    let loadedGeneration = try Configuration.default.write(to: url)
    try Data("# external edit\n".utf8).write(to: url)

    XCTAssertThrowsError(try loadedGeneration.write(to: url)) { error in
      XCTAssertEqual((error as? AllwardError)?.operation, "config.generation")
    }
  }

  func testTargetedWritePreservesCommentsFormattingAndUnknownKeys() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("allward.toml")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = """
    # operator note
    future-key = 'leave this alone'

    [terminal]
    font-size = 13.0 # chosen for this display
    """
    try Data(source.utf8).write(to: url)
    var configuration = try Configuration.load(from: url)
    configuration.terminal.fontSize = 14

    _ = try configuration.write(to: url)
    let written = try String(contentsOf: url, encoding: .utf8)

    XCTAssertTrue(written.contains("# operator note"))
    XCTAssertTrue(written.contains("future-key = 'leave this alone'"))
    XCTAssertTrue(written.contains("font-size = 14.0 # chosen for this display"))
  }

  func testRoomPolicySnapshotAppliesInjectedFocusFilter() async throws {
    let windowID = WindowID()
    let provider = StaticFocusFilterProvider(policies: [Room.personal.id: .deny])
    let store = RoomStore(focusProvider: provider)

    let snapshot = await store.snapshot(for: windowID, appearance: .dark)

    XCTAssertEqual(snapshot.activeRoom.id, Room.personal.id)
    XCTAssertEqual(snapshot.focusPolicy, .deny)
    XCTAssertFalse(snapshot.allowsAmbientPresentation)
    XCTAssertNotEqual(Room.personal.baseTint, Room.work.baseTint)
  }

  func testITerm2ImportMapsAllANSIColoursAndForegroundBackground() throws {
    var entries = ""
    for index in 0..<16 {
      let component = Double(index) / 15.0
      entries += """
      <key>Ansi \(index) Color</key>
      <dict>
        <key>Red Component</key><real>\(component)</real>
        <key>Green Component</key><real>0.25</real>
        <key>Blue Component</key><real>0.5</real>
      </dict>
      """
    }
    let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    \(entries)
    <key>Foreground Color</key><dict>
      <key>Red Component</key><real>0.9</real>
      <key>Green Component</key><real>0.8</real>
      <key>Blue Component</key><real>0.7</real>
    </dict>
    <key>Background Color</key><dict>
      <key>Red Component</key><real>0.05</real>
      <key>Green Component</key><real>0.06</real>
      <key>Blue Component</key><real>0.07</real>
    </dict>
    <key>Cursor Color</key><dict>
      <key>Red Component</key><real>1</real>
      <key>Green Component</key><real>1</real>
      <key>Blue Component</key><real>1</real>
    </dict>
    <key>Selection Color</key><dict>
      <key>Red Component</key><real>0.2</real>
      <key>Green Component</key><real>0.3</real>
      <key>Blue Component</key><real>0.4</real>
    </dict>
    </dict></plist>
    """

    let result = try ThemeImporter.importITerm2(Data(fixture.utf8), name: "Fixture")

    XCTAssertEqual(result.theme.ansi.count, 8)
    XCTAssertEqual(result.theme.brights.count, 8)
    XCTAssertEqual(result.theme.foreground.hexString, "#e6ccb3")
    XCTAssertEqual(result.theme.background.hexString, "#0d0f12")
    XCTAssertTrue(result.unmappedFields.isEmpty)
  }

  func testGhosttyImportMapsPaletteEntries() throws {
    let palette = (0..<16).map { "palette = \($0)=#\(String(format: "%02x", $0 * 10))5070" }
      .joined(separator: "\n")
    let fixture = """
    \(palette)
    background = #101217
    foreground = #e8e4dc
    cursor-color = #f0c674
    selection-background = #394457
    """

    let result = try ThemeImporter.importGhostty(fixture, name: "Fixture")

    XCTAssertEqual(result.theme.ansi[3].hexString, "#1e5070")
    XCTAssertEqual(result.theme.brights[7].hexString, "#965070")
    XCTAssertTrue(result.unmappedFields.isEmpty)
  }

  func testBase16YAMLImportMapsPalette() throws {
    let fixture = """
    scheme: "Fixture Base16"
    base00: "101218"
    base01: "20242d"
    base02: "303744"
    base03: "556070"
    base04: "8993a4"
    base05: "d8dce3"
    base06: "eef0f4"
    base07: "ffffff"
    base08: "e06c75"
    base09: "d19a66"
    base0A: "e5c07b"
    base0B: "98c379"
    base0C: "56b6c2"
    base0D: "61afef"
    base0E: "c678dd"
    base0F: "be5046"
    """

    let result = try ThemeImporter.importBase16YAML(fixture)

    XCTAssertEqual(result.theme.name, "Fixture Base16")
    XCTAssertEqual(result.theme.background.hexString, "#101218")
    XCTAssertEqual(result.theme.foreground.hexString, "#d8dce3")
    XCTAssertEqual(result.theme.ansi.count, 8)
    XCTAssertEqual(result.theme.brights.count, 8)
    XCTAssertEqual(Set(result.unmappedFields), ["cursor", "selection"])
  }

  func testLowContrastPaletteIsReportedWithoutMutation() throws {
    let palette = (0..<16).map { "palette = \($0)=#707070" }.joined(separator: "\n")
    let fixture = """
    \(palette)
    background = #101010
    foreground = #111111
    cursor-color = #121212
    selection-background = #131313
    """

    let result = try ThemeImporter.importGhostty(fixture, name: "Low contrast")
    let originalForeground = result.theme.foreground
    let issues = result.theme.contrastIssues()

    XCTAssertTrue(issues.contains { $0.field == "foreground" })
    XCTAssertEqual(result.theme.foreground, originalForeground)
    XCTAssertEqual(result.theme.foreground.hexString, "#111111")
  }
}
