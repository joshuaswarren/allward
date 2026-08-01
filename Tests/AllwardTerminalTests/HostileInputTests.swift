import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

/// A program must not be able to kill the terminal.
///
/// Four cursor and erase paths added a CSI parameter to the current position
/// and clamped the result afterwards. The parameter is whatever arrived on the
/// pty, up to `Int.max`, so the addition overflowed and trapped before the
/// clamp could run. One escape sequence took the whole app down, and nothing
/// exotic is needed to send it: `cat` of a corrupt file will do.
///
/// Every case here is a real byte sequence fed through the real parser.
final class HostileInputTests: XCTestCase {
    private func terminal(columns: Int = 20, rows: Int = 10) -> Terminal {
        Terminal(
            geometry: TerminalGeometry(columns: columns, rows: rows),
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            scrollbackCapacity: 1000)
    }

    private func send(_ text: String, to terminal: Terminal) {
        terminal.consume(ArraySlice(Array(text.utf8)))
    }

    private let huge = "9223372036854775807"

    func testCursorDownWithAMaximisedParameterDoesNotTrap() {
        let terminal = self.terminal()
        send("\u{1B}[5;5H", to: terminal)
        send("\u{1B}[\(huge)B", to: terminal)
        XCTAssertLessThan(terminal.snapshot().cursor.row, 10)
    }

    func testCursorForwardWithAMaximisedParameterDoesNotTrap() {
        let terminal = self.terminal()
        send("\u{1B}[1;5H", to: terminal)
        send("\u{1B}[\(huge)C", to: terminal)
        XCTAssertLessThan(terminal.snapshot().cursor.column, 20)
    }

    func testCursorUpWithAMaximisedParameterDoesNotTrap() {
        let terminal = self.terminal()
        send("\u{1B}[5;5H", to: terminal)
        send("\u{1B}[\(huge)A", to: terminal)
        XCTAssertEqual(terminal.snapshot().cursor.row, 0)
    }

    func testNextLineWithAMaximisedParameterDoesNotTrap() {
        let terminal = self.terminal()
        send("\u{1B}[3;3H", to: terminal)
        send("\u{1B}[\(huge)E", to: terminal)
        XCTAssertLessThan(terminal.snapshot().cursor.row, 10)
    }

    /// Origin mode with a scrolling region is the case that added the margin
    /// to the parameter, so it overflowed from a different direction.
    func testAbsolutePositionInOriginModeDoesNotTrap() {
        let terminal = self.terminal()
        send("\u{1B}[2;8r", to: terminal)
        send("\u{1B}[?6h", to: terminal)
        send("\u{1B}[\(huge);1H", to: terminal)
        XCTAssertLessThan(terminal.snapshot().cursor.row, 10)
    }

    func testEraseCharactersWithAMaximisedParameterDoesNotTrap() {
        let terminal = self.terminal()
        send("hello", to: terminal)
        send("\u{1B}[1;3H", to: terminal)
        send("\u{1B}[\(huge)X", to: terminal)
        XCTAssertEqual(terminal.snapshot().geometry.columns, 20)
    }

    /// Not a crash but a hang: the tab loop ran the parameter's worth of
    /// iterations, pinning the session actor for the rest of the day.
    func testForwardTabWithAMaximisedParameterReturnsPromptly() {
        let terminal = self.terminal()
        let started = Date()
        send("\u{1B}[\(huge)I", to: terminal)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1,
            "A maximised tab count must be bounded by the width of the row.")
    }

    func testBackwardTabWithAMaximisedParameterReturnsPromptly() {
        let terminal = self.terminal()
        send("\u{1B}[1;20H", to: terminal)
        let started = Date()
        send("\u{1B}[\(huge)Z", to: terminal)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// A one-cell grid is legal and every clamp has to survive it.
    func testASingleCellGridSurvivesHostileMotion() {
        let terminal = self.terminal(columns: 1, rows: 1)
        for suffix in ["A", "B", "C", "D", "E", "X", "I", "Z", "L", "M", "P", "@"] {
            send("\u{1B}[\(huge)\(suffix)", to: terminal)
        }
        send("\u{1B}[\(huge);\(huge)H", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cursor.row, 0)
        XCTAssertEqual(snapshot.cursor.column, 0)
    }

    /// Zero means "one" for these parameters; it must not underflow either.
    func testZeroParametersAreTreatedAsOne() {
        let terminal = self.terminal()
        send("\u{1B}[0;0H", to: terminal)
        send("\u{1B}[0A", to: terminal)
        send("\u{1B}[0D", to: terminal)
        send("\u{1B}[0X", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cursor.row, 0)
        XCTAssertEqual(snapshot.cursor.column, 0)
    }
}
