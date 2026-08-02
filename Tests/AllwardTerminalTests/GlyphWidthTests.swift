import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

/// Column width is a contract between the terminal and the program.
///
/// A program lays out a line by counting columns. If the terminal disagrees,
/// the cursor ends up somewhere the program did not expect and its next write
/// lands on top of what it just drew.
///
/// That is what hid herdr's tick for a whole day of bug reports. Emoji
/// presentation was three hand-written ranges, and `0x2600...0x27BF` swept in
/// the entire Dingbats block, so `✓`, `✗` and `❯` were declared two columns
/// wide. herdr wrote the tick, advanced one column as every other terminal
/// would, and the padding that followed overwrote it. The glyph was drawn and
/// then erased, which is why it looked like a font problem and was not.
///
/// Widths are measured the way a program measures them: print one cluster and
/// read the cursor back.
final class GlyphWidthTests: XCTestCase {
    private func columnsConsumed(by text: String) -> Int {
        let terminal = Terminal(
            geometry: TerminalGeometry(columns: 20, rows: 3),
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            scrollbackCapacity: 100)
        terminal.consume(ArraySlice(Array(text.utf8)))
        return terminal.snapshot().cursor.column
    }

    /// The exact glyphs herdr writes beside an agent.
    func testStatusMarksAreOneColumn() {
        XCTAssertEqual(columnsConsumed(by: "\u{2713}"), 1, "✓ must be one column.")
        XCTAssertEqual(columnsConsumed(by: "\u{2717}"), 1, "✗ must be one column.")
        XCTAssertEqual(columnsConsumed(by: "\u{2714}"), 1, "✔ must be one column.")
    }

    /// The prompt character in Powerlevel10k and Starship.
    func testThePromptChevronIsOneColumn() {
        XCTAssertEqual(columnsConsumed(by: "\u{276F}"), 1, "❯ must be one column.")
    }

    func testSpinnerAndSymbolGlyphsAreOneColumn() {
        for scalar: UInt32 in [0x283C, 0x280B, 0x25CF, 0x25CB, 0x2234, 0x2502, 0x2500] {
            let text = String(Unicode.Scalar(scalar)!)
            XCTAssertEqual(
                columnsConsumed(by: text), 1,
                "U+\(String(format: "%04X", scalar)) must be one column.")
        }
    }

    /// Nerd Font icons live in the private use area and are single width.
    func testPrivateUseIconsAreOneColumn() {
        for scalar: UInt32 in [0xF111, 0xF254, 0xE0B0, 0xF00C] {
            let text = String(Unicode.Scalar(scalar)!)
            XCTAssertEqual(
                columnsConsumed(by: text), 1,
                "U+\(String(format: "%04X", scalar)) must be one column.")
        }
    }

    /// The things that genuinely are two columns must stay two, or the fix
    /// above has simply moved the breakage somewhere else.
    func testGenuinelyWideCharactersStayTwoColumns() {
        XCTAssertEqual(columnsConsumed(by: "\u{4F60}"), 2, "CJK must be two columns.")
        XCTAssertEqual(columnsConsumed(by: "\u{D55C}"), 2, "Hangul must be two columns.")
        XCTAssertEqual(columnsConsumed(by: "\u{2705}"), 2, "✅ is an emoji, two columns.")
        XCTAssertEqual(columnsConsumed(by: "\u{1F600}"), 2, "😀 must be two columns.")
    }

    /// An emoji selector widens a character that has an emoji form, and must
    /// not widen one that does not.
    func testTheEmojiSelectorOnlyWidensRealEmoji() {
        XCTAssertEqual(
            columnsConsumed(by: "\u{2713}\u{FE0F}"), 1,
            "U+2713 has no emoji form, so a selector must not make it wide.")
        XCTAssertEqual(columnsConsumed(by: "\u{2764}\u{FE0F}"), 2, "❤️ is an emoji.")
        XCTAssertEqual(
            columnsConsumed(by: "\u{2705}\u{FE0E}"), 1,
            "A text selector asks for the narrow form.")
    }

    func testPlainASCIIIsOneColumn() {
        XCTAssertEqual(columnsConsumed(by: "A"), 1)
        XCTAssertEqual(columnsConsumed(by: "hello"), 5)
    }
}
