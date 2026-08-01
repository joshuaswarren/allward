import AllwardCore
import AllwardDesign
import AllwardRenderer
import AllwardTerminal
import AppKit
import XCTest

@testable import AllwardChrome

/// The grid is drawn by Metal, so this projection is the only thing VoiceOver
/// can read. Its offsets have to be exact: the engine counts in cells and every
/// accessibility query is in UTF-16, and the two only agree while the screen is
/// pure ASCII.
final class TerminalAccessibilityTests: XCTestCase {
    private func snapshot(
        rows: [[TerminalCell]], cursor: CursorState = CursorState(
            row: 0, column: 0, visible: true, shape: .block),
        selection: Selection? = nil
    ) -> TerminalSnapshot {
        let columns = rows.map(\.count).max() ?? 0
        return TerminalSnapshot(
            generation: .initial,
            geometry: TerminalGeometry(columns: max(1, columns), rows: max(1, rows.count)),
            rows: rows,
            rowIDs: (0 ..< max(1, rows.count)).map { LineID(rawValue: UInt64($0 + 1)) },
            cursor: cursor,
            modes: TerminalModes(),
            selection: selection)
    }

    private func cells(_ text: String) -> [TerminalCell] {
        text.map { TerminalCell(text: String($0)) }
    }

    func testEachRowBecomesItsOwnNavigableLine() {
        let projection = TerminalTextProjection(
            snapshot: snapshot(rows: [cells("alpha"), cells("beta"), cells("gamma")]))
        XCTAssertEqual(projection.lineRanges.count, 3)
        XCTAssertEqual(projection.string(for: projection.range(forLine: 0)), "alpha")
        XCTAssertEqual(projection.string(for: projection.range(forLine: 1)), "beta")
        XCTAssertEqual(projection.string(for: projection.range(forLine: 2)), "gamma")
    }

    func testACharacterOffsetResolvesToItsLine() {
        let projection = TerminalTextProjection(
            snapshot: snapshot(rows: [cells("alpha"), cells("beta")]))
        XCTAssertEqual(projection.line(for: 0), 0)
        XCTAssertEqual(projection.line(for: 4), 0)
        // "alpha\n" is six UTF-16 units, so the seventh belongs to line 1.
        XCTAssertEqual(projection.line(for: 7), 1)
    }

    func testCursorOffsetSurvivesAWideGlyph() {
        // A wide glyph is one character in two cells. A cursor in column 4 sits
        // after two of them, which is UTF-16 offset 2, not 4.
        var row: [TerminalCell] = []
        for _ in 0 ..< 2 {
            row.append(TerminalCell(text: "漢", span: .wide))
            row.append(TerminalCell(text: "", span: .continuation))
        }
        let projection = TerminalTextProjection(
            snapshot: snapshot(
                rows: [row],
                cursor: CursorState(row: 0, column: 4, visible: true, shape: .block)))
        XCTAssertEqual(projection.cursorRange.location, 2)
        XCTAssertEqual(projection.cursorLine, 0)
    }

    func testSelectionOffsetSurvivesAWideGlyph() {
        var row: [TerminalCell] = []
        for _ in 0 ..< 3 {
            row.append(TerminalCell(text: "漢", span: .wide))
            row.append(TerminalCell(text: "", span: .continuation))
        }
        let line = LineID(rawValue: 1)
        let selection = Selection(
            start: SelectionAnchor(line: line, graphemeOffset: 0),
            end: SelectionAnchor(line: line, graphemeOffset: 4),
            mode: .stream)
        let projection = TerminalTextProjection(
            snapshot: snapshot(rows: [row], selection: selection))
        // Four cells of wide glyphs is two characters.
        XCTAssertEqual(projection.selectedRange?.location, 0)
        XCTAssertEqual(projection.selectedRange?.length, 2)
        XCTAssertEqual(projection.string(for: projection.selectedRange!), "漢漢")
    }

    func testAsciiOffsetsStillLineUpOneToOne() {
        let projection = TerminalTextProjection(
            snapshot: snapshot(
                rows: [cells("hello world")],
                cursor: CursorState(row: 0, column: 6, visible: true, shape: .block)))
        XCTAssertEqual(projection.cursorRange.location, 6)
        XCTAssertEqual(
            projection.string(for: NSRange(location: 6, length: 5)), "world")
    }

    func testNoSelectionMeansNoSelectedRange() {
        let projection = TerminalTextProjection(snapshot: snapshot(rows: [cells("plain")]))
        XCTAssertNil(projection.selectedRange)
    }

    @MainActor
    func testFocusRingStaysLegibleWhenChromeAndGridDisagree() {
        // The chrome palette follows macOS and the grid follows the Room, so a
        // dark ring can land on a light grid. It measured 1.90:1 before this.
        for appearance in Appearance.allCases {
            let palette = DesignPalette(appearance: appearance, settings: .standard)
            for theme in [TerminalTheme.builtInDark] {
                let ring = TerminalPaneView.focusRingColor(palette: palette, theme: theme)
                XCTAssertGreaterThanOrEqual(
                    ring.contrastRatio(against: theme.defaultBackground), 3,
                    "focus ring must clear 3:1 against the grid it is drawn on")
            }
        }
    }
}
