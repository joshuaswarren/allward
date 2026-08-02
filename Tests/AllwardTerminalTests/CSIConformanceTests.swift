import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

/// A terminal emulator must accurately decode, apply, query, and bound CSI, DCS, SS3, and ESC sequences.
///
/// Real terminal applications (ncurses, vim, htop, tmux, modern CLI tools) depend on device reports,
/// mode queries, cursor styling, synchronized output, and window operations to render correctly.
final class CSIConformanceTests: XCTestCase {
    private func terminal(columns: Int = 80, rows: Int = 24) -> Terminal {
        Terminal(
            geometry: TerminalGeometry(columns: columns, rows: rows),
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            scrollbackCapacity: 1000
        )
    }

    private func send(_ text: String, to terminal: Terminal) {
        terminal.consume(ArraySlice(Array(text.utf8)))
    }

    private func sendBytes(_ bytes: [UInt8], to terminal: Terminal) {
        terminal.consume(ArraySlice(bytes))
    }

    // MARK: - 1. Device Reports (DA1, DA2, DA3, DSR)

    /// Programs send Primary DA (`CSI c` or `CSI ? c`) to detect terminal capabilities; falling back to dumb mode if unanswered.
    func testPrimaryDeviceAttributesQueryReturnsVT220Response() {
        let terminal = self.terminal()
        send("\u{1B}[c", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?62;22c")
    }

    func testPrimaryDeviceAttributesWithQuestionMarkReturnsVT220Response() {
        let terminal = self.terminal()
        send("\u{1B}[?c", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?62;22c")
    }

    /// Secondary DA (`CSI > c`) returns terminal type, version, and hardware flags.
    func testSecondaryDeviceAttributesQueryReturnsIdentification() {
        let terminal = self.terminal()
        send("\u{1B}[>c", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[>41;386;0c")
    }

    /// Tertiary DA (`CSI = c`) returns unit ID in DCS format.
    func testTertiaryDeviceAttributesQueryReturnsUnitID() {
        let terminal = self.terminal()
        send("\u{1B}[=c", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P!|00000000\u{1B}\\")
    }

    /// DSR Status Report (`CSI 5 n`) returns ready status (`CSI 0 n`).
    func testDeviceStatusReportStatusReturnsOK() {
        let terminal = self.terminal()
        send("\u{1B}[5n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[0n")
    }

    /// DSR Cursor Position Report (`CSI 6 n`) returns row and column.
    func testDeviceStatusReportCursorPositionReturns1BasedCoordinates() {
        let terminal = self.terminal()
        send("Hello\r\n", to: terminal)
        send("\u{1B}[6n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[2;1R")
    }

    /// DEC Extended CPR (`CSI ? 6 n`) returns row, column, and page number 1.
    func testDECExtendedCursorPositionReportIncludesPageNumber() {
        let terminal = self.terminal()
        send("\u{1B}[?6n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?1;1;1R")
    }

    /// DSR Printer (`CSI 15 n`), UDK (`CSI 25 n`), Keyboard (`CSI 26 n`) queries respond without hanging.
    func testAuxiliaryDeviceStatusReportsReturnValidReplies() {
        let terminal = self.terminal()
        send("\u{1B}[15n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?13n")
        send("\u{1B}[25n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?23n")
        send("\u{1B}[26n", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?27;1;0;0n")
    }

    // MARK: - 2. DECRQM / DECRPM (Report Mode)

    /// Programs use DECRQM to query whether bracketed paste (2004) is enabled or supported.
    func testDECRQMQueriesBracketedPasteMode() {
        let terminal = self.terminal()
        send("\u{1B}[?2004$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?2004;2$y")

        send("\u{1B}[?2004h", to: terminal)
        send("\u{1B}[?2004$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?2004;1$y")
    }

    /// DECRQM queries for SGR mouse (1006) and synchronized output (2026).
    func testDECRQMQueriesSGRMouseAndSynchronizedOutput() {
        let terminal = self.terminal()
        send("\u{1B}[?1006$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?1006;2$y")

        send("\u{1B}[?2026$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?2026;2$y")
    }

    /// ANSI mode query (`CSI 4 $ p` for insert mode).
    func testDECRQMQueriesANSIMode() {
        let terminal = self.terminal()
        send("\u{1B}[4$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[4;2$y")
    }

    /// DECRQM for an unknown mode responds with 0 (not recognized).
    func testDECRQMForUnknownModeReturnsNotRecognized() {
        let terminal = self.terminal()
        send("\u{1B}[?9999$p", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[?9999;0$y")
    }

    // MARK: - 3. XTVERSION (Terminal Name & Version)

    /// Modern capability detectors send `CSI > 0 q` to get terminal version.
    func testXTVERSIONQueryReturnsTerminalNameAndVersion() {
        let terminal = self.terminal()
        send("\u{1B}[>0q", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P>|Allward(0.1.0)\u{1B}\\")
    }

    // MARK: - 4. Synchronized Output (DEC 2026)

    /// Frame sync mode 2026 prevents screen tearing during complex TUI redraws.
    func testSynchronizedOutputModeTogglesState() {
        let terminal = self.terminal()
        XCTAssertFalse(terminal.snapshot().modes.synchronizedOutput)

        send("\u{1B}[?2026h", to: terminal)
        XCTAssertTrue(terminal.snapshot().modes.synchronizedOutput)

        send("\u{1B}[?2026l", to: terminal)
        XCTAssertFalse(terminal.snapshot().modes.synchronizedOutput)
    }

    // MARK: - 5. DECRQSS (Request Selection / Setting)

    /// Query SGR (`DCS $ q m ST`).
    func testDECRQSSQueriesGraphicRendition() {
        let terminal = self.terminal()
        send("\u{1B}P$qm\u{1B}\\", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P1$r0m\u{1B}\\")
    }

    /// Query vertical margins (`DCS $ q r ST`).
    func testDECRQSSQueriesVerticalMargins() {
        let terminal = self.terminal(rows: 24)
        send("\u{1B}P$qr\u{1B}\\", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P1$r1;24r\u{1B}\\")
    }

    /// Query cursor style (`DCS $ q " q ST`).
    func testDECRQSSQueriesCursorStyle() {
        let terminal = self.terminal()
        send("\u{1B}P$q\"q\u{1B}\\", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P1$r1 \" q\u{1B}\\")
    }

    /// Query unknown setting responds with invalid status (`DCS 0 $ r ... ST`).
    func testDECRQSSQueryForUnknownSettingReturnsInvalid() {
        let terminal = self.terminal()
        send("\u{1B}P$qinvalid\u{1B}\\", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P0$rinvalid\u{1B}\\")
    }

    // MARK: - 6. XTGETTCAP (Terminfo Query)

    /// Terminfo queries (`DCS + q ... ST`) return invalid response cleanly when unsupported.
    func testXTGETTCAPReturnsUnsupportedStatus() {
        let terminal = self.terminal()
        send("\u{1B}P+q544e#3\u{1B}\\", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}P0+r\u{1B}\\")
    }

    // MARK: - 7. DECSCUSR, DECSTBM, DECSLRM, DECSC/DECRC, DECALN

    /// DECSCUSR (`CSI Ps SP q`) configures cursor shape and blinking.
    func testDECSCUSRUpdatesCursorStyle() {
        let terminal = self.terminal()
        send("\u{1B}[2 q", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.cursorStyle, .steadyBlock)

        send("\u{1B}[5 q", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.cursorStyle, .blinkingBar)
    }

    /// DECSTBM (`CSI top ; bottom r`) sets vertical scrolling margins and resets cursor to (1,1).
    func testDECSTBMConfiguresScrollingMargins() {
        let terminal = self.terminal(rows: 24)
        send("\u{1B}[5;20r", to: terminal)
        XCTAssertEqual(terminal.snapshot().cursor.row, 0)
        XCTAssertEqual(terminal.snapshot().cursor.column, 0)
    }

    /// DECSLRM (`CSI left ; right s`) sets left/right margins cleanly when 2 parameters are supplied.
    func testDECSLRMAcceptedWithoutError() {
        let terminal = self.terminal()
        send("\u{1B}[5;15s", to: terminal)
    }

    /// DECSC (`ESC 7`) and DECRC (`ESC 8`) save and restore cursor state.
    func testSaveAndRestoreCursorPreservesPosition() {
        let terminal = self.terminal()
        send("\u{1B}[10;15H", to: terminal)
        send("\u{1B}7", to: terminal)
        send("\u{1B}[1;1H", to: terminal)
        send("\u{1B}8", to: terminal)
        XCTAssertEqual(terminal.snapshot().cursor.row, 9)
        XCTAssertEqual(terminal.snapshot().cursor.column, 14)
    }

    /// DECALN (`ESC # 8`) fills the screen with alignment test characters ('E').
    func testScreenAlignmentTestFillsScreenWithE() {
        let terminal = self.terminal(columns: 5, rows: 2)
        send("\u{1B}#8", to: terminal)
        let row0 = terminal.snapshot().rows[0].map(\.text).joined()
        XCTAssertEqual(row0, "EEEEE")
    }

    // MARK: - 8. Mouse Modes & Focus Events

    /// Mouse modes (1000, 1002, 1003, 1004, 1006, 1005, 1015, 1016) set state cleanly.
    func testMouseAndFocusModesToggleState() {
        let terminal = self.terminal()
        send("\u{1B}[?1000h", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.mouseTracking, .pressRelease)

        send("\u{1B}[?1002h", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.mouseTracking, .buttonMotion)

        send("\u{1B}[?1003h", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.mouseTracking, .anyMotion)

        send("\u{1B}[?1004h", to: terminal)
        XCTAssertTrue(terminal.snapshot().modes.focusReporting)

        send("\u{1B}[?1006h", to: terminal)
        XCTAssertEqual(terminal.snapshot().modes.mouseEncoding, .sgr)

        send("\u{1B}[?1005h\u{1B}[?1015h\u{1B}[?1016h", to: terminal)
    }

    // MARK: - 9. Modes, REP, DECSTR & Window Ops

    /// Character repetition (`CSI Ps b`).
    func testRepeatPrecedingCharacter() {
        let terminal = self.terminal()
        send("A\u{1B}[4b", to: terminal)
        let line = terminal.snapshot().rows[0].prefix(5).map(\.text).joined()
        XCTAssertEqual(line, "AAAAA")
    }

    /// Soft Terminal Reset (`CSI ! p`).
    func testSoftTerminalResetRestoresDefaults() {
        let terminal = self.terminal()
        send("\u{1B}[?2004h\u{1B}[?1004h", to: terminal)
        XCTAssertTrue(terminal.snapshot().modes.bracketedPaste)
        XCTAssertTrue(terminal.snapshot().modes.focusReporting)

        send("\u{1B}[!p", to: terminal)
        XCTAssertFalse(terminal.snapshot().modes.bracketedPaste)
        XCTAssertFalse(terminal.snapshot().modes.focusReporting)
    }

    /// Window Operations (`CSI 14 t`, `CSI 18 t`, `CSI 19 t`).
    func testWindowOperationsReturnDimensions() {
        let terminal = self.terminal(columns: 80, rows: 24)
        send("\u{1B}[14t", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[4;768;1024t")

        send("\u{1B}[18t", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[8;24;80t")

        send("\u{1B}[19t", to: terminal)
        XCTAssertEqual(String(decoding: terminal.pendingResponses, as: UTF8.self), "\u{1B}[9;24;80t")
    }

    /// G0..G3 Character Set Designations (`ESC ( B`, `ESC ( 0`) consumed cleanly.
    func testCharacterSetDesignationsConsumedCleanly() {
        let terminal = self.terminal()
        send("\u{1B}(BText\u{1B}(0", to: terminal)
        let line = terminal.snapshot().rows[0].prefix(4).map(\.text).joined()
        XCTAssertEqual(line, "Text")
    }
}
