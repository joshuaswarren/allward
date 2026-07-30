import Foundation
import XCTest
import AllwardCore
@testable import AllwardTerminal

final class TerminalEngineTests: XCTestCase {
  private func terminal(columns: Int = 8, rows: Int = 4, capacity: Int = 10_000) -> Terminal {
    Terminal(
      geometry: TerminalGeometry(columns: columns, rows: rows),
      clock: FixedClock(Date(timeIntervalSince1970: 100)),
      scrollbackCapacity: capacity
    )
  }

  private func send(_ text: String, to terminal: Terminal) {
    terminal.consume(Array(text.utf8)[...])
  }

  func testUTF8SplitAcrossChunks() {
    let terminal = terminal()
    let bytes = Array("A🙂B".utf8)
    terminal.consume(bytes[0...2])
    terminal.consume(bytes[3...])
    XCTAssertEqual(terminal.snapshot().plainText(row: 0), "A🙂B")
  }

  func testWideAndCombiningClusters() {
    let terminal = terminal()
    send("界e\u{301}", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.rows[0][0].span, .wide)
    XCTAssertEqual(snapshot.rows[0][1].span, .continuation)
    XCTAssertEqual(snapshot.rows[0][2].text, "e\u{301}")
    XCTAssertEqual(snapshot.cursor.column, 3)
  }

  func testAutoWrapWaitsForNextPrintable() {
    let terminal = terminal(columns: 3, rows: 3)
    send("abc", to: terminal)
    XCTAssertTrue(terminal.snapshot().cursor.wrapPending)
    send("d", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.plainText(row: 0), "abc")
    XCTAssertEqual(snapshot.plainText(row: 1), "d")
    XCTAssertEqual(snapshot.cursor.row, 1)
    XCTAssertEqual(snapshot.cursor.column, 1)
  }

  func testScrollRegionScrollAndLineInsertionDeletion() {
    let terminal = terminal(columns: 4, rows: 4)
    send("1111\r\n2222\r\n3333\r\n4444", to: terminal)
    send("\u{1B}[2;3r\u{1B}[2;1H\u{1B}[S", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 1), "3333")
    send("\u{1B}[L", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 2), "3333")
    send("\u{1B}[M", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 1), "3333")
    send("\u{1B}[T", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 1), "")
    XCTAssertEqual(terminal.snapshot().plainText(row: 2), "3333")
    XCTAssertEqual(terminal.snapshot().plainText(row: 3), "4444")
  }

  func testEraseInDisplayAndLineVariants() {
    for (mode, expected) in [(0, "ab"), (1, "   de"), (2, "")] {
      let subject = terminal(columns: 5, rows: 3)
      send("abcde\u{1B}[1;3H\u{1B}[\(mode)K", to: subject)
      XCTAssertEqual(subject.snapshot().plainText(row: 0), expected)
    }

    let after = terminal(columns: 5, rows: 3)
    send("abcde\r\nfghij\r\nklmno\u{1B}[2;3H\u{1B}[0J", to: after)
    XCTAssertEqual(after.snapshot().plainText(row: 0), "abcde")
    XCTAssertEqual(after.snapshot().plainText(row: 1), "fg")
    XCTAssertEqual(after.snapshot().plainText(row: 2), "")

    let before = terminal(columns: 5, rows: 3)
    send("abcde\r\nfghij\r\nklmno\u{1B}[2;3H\u{1B}[1J", to: before)
    XCTAssertEqual(before.snapshot().plainText(row: 0), "")
    XCTAssertEqual(before.snapshot().plainText(row: 1), "   ij")
    XCTAssertEqual(before.snapshot().plainText(row: 2), "klmno")

    let all = terminal(columns: 5, rows: 3)
    send("abcde\r\nfghij\r\nklmno\u{1B}[2J", to: all)
    XCTAssertTrue(all.snapshot().rows.flatMap { $0 }.allSatisfy(\.isBlank))
  }

  func testInsertAndDeleteCharacters() {
    let terminal = terminal(columns: 6, rows: 2)
    send("abcdef\u{1B}[1;3H\u{1B}[2@", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 0), "ab  cd")
    send("\u{1B}[1P", to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 0), "ab cd")
  }

  func testSavedCursorRestoresAttributesAndOriginMode() {
    let terminal = terminal()
    send("\u{1B}[31;1m\u{1B}[?6h\u{1B}[2;3r\u{1B}[2;2H\u{1B}7", to: terminal)
    send("\u{1B}[0m\u{1B}[?6l\u{1B}[1;1H\u{1B}8X", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.rows[2][1].text, "X")
    XCTAssertEqual(snapshot.rows[2][1].attributes.foreground, .indexed(1))
    XCTAssertTrue(snapshot.rows[2][1].attributes.flags.contains(.bold))
    XCTAssertTrue(snapshot.modes.originMode)
  }

  func testSGR256TrueColorAndEveryFlag() {
    let terminal = terminal(columns: 4)
    send(
      "\u{1B}[1;2;3;4;5;7;8;9;38;5;123;48;2;1;2;3;58;2;4;5;6mX"
        + "\u{1B}[21mY\u{1B}[4:3mZ\u{1B}[1\"qW",
      to: terminal
    )
    let snapshot = terminal.snapshot()
    let attributes = snapshot.rows[0][0].attributes
    XCTAssertEqual(attributes.foreground, .indexed(123))
    XCTAssertEqual(attributes.background, .rgb(1, 2, 3))
    XCTAssertEqual(attributes.underlineColor, .rgb(4, 5, 6))
    let flags: [CellAttributes.Flags] = [
      .bold, .faint, .italic, .underline, .blink, .inverse, .invisible, .strikethrough,
    ]
    for flag in flags {
      XCTAssertTrue(attributes.flags.contains(flag))
    }
    XCTAssertTrue(snapshot.rows[0][1].attributes.flags.contains(.doubleUnderline))
    XCTAssertTrue(snapshot.rows[0][2].attributes.flags.contains(.curlyUnderline))
    XCTAssertTrue(snapshot.rows[0][3].attributes.flags.contains(.protected))
  }
  func testSelectiveErasePreservesProtectedCells() {
    let terminal = terminal(columns: 4)
    send("\u{1B}[1\"q\u{1B}[0mX\u{1B}[0\"qY\u{1B}[1G\u{1B}[?2K", to: terminal)
    let row = terminal.snapshot().rows[0]
    XCTAssertEqual(row[0].text, "X")
    XCTAssertTrue(row[1].isBlank)
  }


  func testAlternateScreen1049PreservesPrimaryWithoutScrollback() {
    let terminal = terminal(columns: 4, rows: 2)
    send("main", to: terminal)
    send("\u{1B}[?1049halt\r\nmore\r\nlines\u{1B}[?1049l", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.plainText(row: 0), "main")
    XCTAssertEqual(snapshot.scrollbackCount, 0)
    XCTAssertFalse(snapshot.modes.alternateScreen)
  }

  func testOSCMetadataAndCommandRegion() {
    let terminal = terminal(columns: 20, rows: 4)
    send("\u{1B}]2;Build pane\u{7}", to: terminal)
    send("\u{1B}]7;file://host/tmp/project\u{7}", to: terminal)
    send("\u{1B}]8;id=docs;https://example.com\u{7}link\u{1B}]8;;\u{7}", to: terminal)
    send("\u{1B}]133;A;aid=42\u{7}$ \u{1B}]133;B;aid=42\u{7}echo hi", to: terminal)
    send("\u{1B}]133;C;aid=42\u{7}hi\r\n\u{1B}]133;D;aid=42;exit=7\u{7}", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.title, "Build pane")
    XCTAssertNotNil(snapshot.rows[0][0].attributes.hyperlinkID)
    XCTAssertNil(snapshot.rows[0][4].attributes.hyperlinkID)
    let region = snapshot.commandRegions.last
    XCTAssertEqual(region?.exitCode, 7)
    XCTAssertEqual(region?.commandText, "echo hi")
    XCTAssertEqual(region?.workingDirectory, "/tmp/project")
  }

  func testTabStopsCanBeSetClearedAndTraversed() {
    let terminal = terminal(columns: 20)
    send("\u{1B}[3g\u{1B}[6G\u{1B}H\u{1B}[11G\u{1B}H\r\u{1B}[Ix\u{1B}[Iy\u{1B}[Z", to: terminal)
    let snapshot = terminal.snapshot()
    XCTAssertEqual(snapshot.rows[0][5].text, "x")
    XCTAssertEqual(snapshot.rows[0][10].text, "y")
    XCTAssertEqual(snapshot.cursor.column, 10)
  }

  func testScrollbackEvictionInvalidatesOnlyEvictedAnchor() {
    let terminal = terminal(columns: 4, rows: 2, capacity: 2)
    send("one\r\ntwo", to: terminal)
    let initial = terminal.snapshot()
    let evicted = SelectionAnchor(line: initial.rowIDs[0], graphemeOffset: 0)
    let retained = SelectionAnchor(line: initial.rowIDs[1], graphemeOffset: 1)
    send("\r\ntri\r\nfou", to: terminal)
    let retainedSelection = Selection(start: retained, end: retained)
    terminal.setSelection(retainedSelection)
    send("\r\nfiv", to: terminal)
    XCTAssertEqual(terminal.snapshot().selection, retainedSelection)
    terminal.setSelection(Selection(start: evicted, end: retained))
    XCTAssertNil(terminal.snapshot().selection)
  }

  func testResizeReflowPreservesSelectionAnchor() {
    let terminal = terminal(columns: 6, rows: 3)
    send("abcdefghi", to: terminal)
    let id = terminal.snapshot().rowIDs[0]
    let selection = Selection(
      start: SelectionAnchor(line: id, graphemeOffset: 1),
      end: SelectionAnchor(line: id, graphemeOffset: 5)
    )
    terminal.setSelection(selection)
    terminal.resize(to: TerminalGeometry(columns: 3, rows: 4))
    XCTAssertEqual(terminal.snapshot().selection, selection)
    XCTAssertEqual(terminal.selectedText(), "bcde")
  }

  func testMalformedCSIWithTooManyParametersResynchronizes() {
    let terminal = terminal()
    let malformed = "\u{1B}[" + Array(repeating: "1;", count: 200).joined() + "mOK"
    send(malformed, to: terminal)
    XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
  }

  func testParserRecoveryUnicodeAndEraseSavedLines() {
    let unicode = terminal(columns: 8)
    send("가©\u{FE0F}", to: unicode)
    let unicodeSnapshot = unicode.snapshot()
    XCTAssertEqual(unicodeSnapshot.rows[0][0].text, "가")
    XCTAssertEqual(unicodeSnapshot.rows[0][0].span, .wide)
    XCTAssertEqual(unicodeSnapshot.rows[0][2].text, "©\u{FE0F}")
    XCTAssertEqual(unicodeSnapshot.rows[0][2].span, .wide)

    let c1 = terminal()
    c1.consume(([0x9D] + Array("2;C1 title".utf8) + [0x9C] + Array("X".utf8))[...])
    XCTAssertEqual(c1.snapshot().title, "C1 title")
    XCTAssertEqual(c1.snapshot().plainText(row: 0), "X")

    let recovery = terminal()
    let overflow = Array("\u{1B}]2;".utf8) + Array(repeating: 0x61, count: 8_193) + [0x07]
    recovery.consume((overflow + Array("OK".utf8))[...])
    XCTAssertEqual(recovery.snapshot().plainText(row: 0), "OK")

    let eraseHistory = terminal(columns: 4, rows: 2)
    send("one\r\ntwo\r\ntri", to: eraseHistory)
    let visible = eraseHistory.snapshot().rows
    send("\u{1B}[3J", to: eraseHistory)
    XCTAssertEqual(eraseHistory.snapshot().rows, visible)
    XCTAssertEqual(eraseHistory.snapshot().scrollbackCount, 0)
  }

  func testZeroRedTruecolorAndMainReturnInApplicationKeypadMode() {
    let terminal = terminal()
    send("\u{1B}[38;2;0;1;2;1mX", to: terminal)
    let attributes = terminal.snapshot().rows[0][0].attributes
    XCTAssertEqual(attributes.foreground, .rgb(0, 1, 2))
    XCTAssertTrue(attributes.flags.contains(.bold))

    var modes = TerminalModes()
    modes.applicationKeypad = true
    let enter = KeyEvent(
      characters: "\r",
      keyCode: 36,
      shift: false,
      control: false,
      option: false,
      command: false
    )
    XCTAssertEqual(InputEncoder.encode(keyEvent: enter, modes: modes), [0x0D])
  }

  func testInputEncodingCursorModesAndSGRMouse() {
    var modes = TerminalModes()
    let up = KeyEvent(
      characters: "",
      keyCode: 126,
      shift: false,
      control: false,
      option: false,
      command: false
    )
    XCTAssertEqual(InputEncoder.encode(keyEvent: up, modes: modes), Array("\u{1B}[A".utf8))
    modes.applicationCursorKeys = true
    XCTAssertEqual(InputEncoder.encode(keyEvent: up, modes: modes), Array("\u{1B}OA".utf8))
    modes.mouseTracking = .pressRelease
    modes.mouseEncoding = .sgr
    XCTAssertEqual(
      InputEncoder.encode(
        mouseButton: 0,
        pressed: true,
        row: 2,
        column: 4,
        modifiers: [],
        modes: modes
      ),
      Array("\u{1B}[<0;5;3M".utf8)
    )
  }
}
