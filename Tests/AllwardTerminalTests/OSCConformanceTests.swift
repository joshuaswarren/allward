import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

/// A terminal emulator must accurately decode, apply, query, and bound OSC sequences.
///
/// OSC (Operating System Command) escape sequences allow programs running inside the terminal
/// to set window titles, configure dynamic palette colors, report shell integration state,
/// pass hyperlinks, issue desktop notifications, and set clipboard contents.
///
/// Both `BEL` (`\u{07}`) and `ST` (`\u{1B}\\`) string terminators must be supported identically.
/// Malformed, unknown, unterminated, or oversized OSC payloads must never crash the terminal engine
/// or corrupt subsequent visible text rendering.
final class OSCConformanceTests: XCTestCase {
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

    // MARK: - 1. OSC 0 / 1 / 2 Window & Icon Titles

    /// TUI applications and shell status scripts rely on OSC 0 to set both icon and window titles simultaneously.
    func testSettingIconNameAndWindowTitleWithOSC0UpdatesTitle() {
        let terminal = self.terminal()
        send("\u{1B}]0;Combined Title\u{07}", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "Combined Title")
    }

    /// Shell prompts set icon titles via OSC 1 to identify tab or window state in window managers.
    func testSettingIconNameWithOSC1UpdatesTitle() {
        let terminal = self.terminal()
        send("\u{1B}]1;Icon Name Only\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "Icon Name Only")
    }

    /// Terminal applications set the main window title via OSC 2 to reflect active editing targets or hostnames.
    func testSettingWindowTitleWithOSC2UpdatesTitle() {
        let terminal = self.terminal()
        send("\u{1B}]2;Window Title Only\u{07}", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "Window Title Only")
    }

    /// Titles frequently contain semicolons when showing status, path components, or command lines; payload parsing must not split title strings on internal semicolons.
    func testSettingTitleContainingSemicolonsDoesNotSplitPayload() {
        let terminal = self.terminal()
        send("\u{1B}]2;project: main.swift; status: editing; v1.0\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "project: main.swift; status: editing; v1.0")
    }

    // MARK: - 2. OSC 4 Palette Entries

    /// Custom terminal themes set individual ANSI palette entries using standard hex color strings.
    func testSettingPaletteEntryWithHexFormatAppliesColor() {
        let terminal = self.terminal()
        send("\u{1B}]4;1;#ff0000\u{07}", to: terminal)
        send("\u{1B}]4;1;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.contains("4;1;"))
    }

    /// Applications use XParseColor `rgb:RR/GG/BB` format when setting palette entries.
    func testSettingPaletteEntryWithRGBFormatAppliesColor() {
        let terminal = self.terminal()
        send("\u{1B}]4;2;rgb:00/ff/00\u{1B}\\", to: terminal)
        send("\u{1B}]4;2;?\u{1B}\\", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.contains("4;2;"))
    }

    /// Terminal tools like `dircolors` query palette entries with `?` and expect a formatted `\u{1B}]4;N;rgb:RRRR/GGGG/BBBB` reply.
    func testQueryingPaletteEntryRepliesWithFormattedRGBColor() {
        let terminal = self.terminal()
        send("\u{1B}]4;1;#ff0000\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]4;1;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("\u{1B}]4;1;rgb:"))
    }

    /// Terminal themes send multiple index-color pairs in a single OSC 4 command to update palette slots efficiently.
    func testSettingMultiplePalettePairsInSingleCommandAppliesAll() {
        let terminal = self.terminal()
        send("\u{1B}]4;1;#ff0000;2;#00ff00;3;#0000ff\u{1B}\\", to: terminal)
        send("\u{1B}]4;1;?;2;?;3;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.contains("4;1;rgb:"))
        XCTAssertTrue(response.contains("4;2;rgb:"))
        XCTAssertTrue(response.contains("4;3;rgb:"))
    }

    // MARK: - 3. OSC 10 / 11 / 12 Dynamic Colours

    /// Editors query foreground color with `OSC 10 ; ?` to determine text contrast settings.
    func testSettingAndQueryingForegroundColourWithOSC10RepliesWithActiveColor() {
        let terminal = self.terminal()
        send("\u{1B}]10;#123456\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]10;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("\u{1B}]10;rgb:"))
    }

    /// Neovim, Vim, and Helix query background color via `OSC 11 ; ?` on startup; a missing reply causes dark text to be painted on dark terminal backgrounds.
    func testQueryingBackgroundColourWithOSC11RepliesWithCurrentColor() {
        let terminal = self.terminal()
        send("\u{1B}]11;?\u{1B}\\", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("\u{1B}]11;rgb:"))
    }

    /// TUI utilities query cursor color via OSC 12 to save and restore custom block cursor appearances.
    func testSettingAndQueryingCursorColourWithOSC12RepliesWithActiveColor() {
        let terminal = self.terminal()
        send("\u{1B}]12;#00ff00\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]12;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("\u{1B}]12;rgb:"))
    }

    // MARK: - 4. OSC 104 / 110 / 111 / 112 Color Resets

    /// Applications issue OSC 104 on cleanup to restore altered palette entries back to theme default values.
    func testResettingPaletteEntriesWithOSC104RestoresOriginalDefaultColor() {
        let terminal = self.terminal()
        send("\u{1B}]4;1;?\u{07}", to: terminal)
        let original = String(decoding: terminal.pendingResponses, as: UTF8.self)
        send("\u{1B}]4;1;#ff0000\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]104;1\u{1B}\\", to: terminal)
        send("\u{1B}]4;1;?\u{07}", to: terminal)
        let restored = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(restored, original)
    }

    /// Shell tools send OSC 110 to reset modified foreground colors back to terminal defaults on program exit.
    func testResettingForegroundColourWithOSC110RestoresDefaultColor() {
        let terminal = self.terminal()
        send("\u{1B}]10;?\u{07}", to: terminal)
        let original = String(decoding: terminal.pendingResponses, as: UTF8.self)
        send("\u{1B}]10;#ff0000\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]110\u{07}", to: terminal)
        send("\u{1B}]10;?\u{07}", to: terminal)
        let restored = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(restored, original)
    }

    /// Shell tools send OSC 111 to reset modified background colors back to terminal defaults on program exit.
    func testResettingBackgroundColourWithOSC111RestoresDefaultColor() {
        let terminal = self.terminal()
        send("\u{1B}]11;?\u{1B}\\", to: terminal)
        let original = String(decoding: terminal.pendingResponses, as: UTF8.self)
        send("\u{1B}]11;#00ff00\u{1B}\\", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]111\u{1B}\\", to: terminal)
        send("\u{1B}]11;?\u{1B}\\", to: terminal)
        let restored = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(restored, original)
    }

    /// Shell tools send OSC 112 to reset modified cursor colors back to terminal defaults on program exit.
    func testResettingCursorColourWithOSC112RestoresDefaultColor() {
        let terminal = self.terminal()
        send("\u{1B}]12;?\u{07}", to: terminal)
        let original = String(decoding: terminal.pendingResponses, as: UTF8.self)
        send("\u{1B}]12;#0000ff\u{07}", to: terminal)
        _ = terminal.pendingResponses
        send("\u{1B}]112\u{07}", to: terminal)
        send("\u{1B}]12;?\u{07}", to: terminal)
        let restored = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(restored, original)
    }

    // MARK: - 5. OSC 7 Working Directory

    /// Shells send OSC 7 with `file://host/path` URLs so new terminal panes open in the current working directory.
    func testSettingWorkingDirectoryWithOSC7ParsesFileURLScheme() {
        let terminal = self.terminal()
        send("\u{1B}]7;file://localhost/tmp/project\u{07}", to: terminal)
        send("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}pwd\u{1B}]133;C\u{07}/tmp/project\r\n\u{1B}]133;D;exit=0\u{07}", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.commandRegions.last?.workingDirectory, "/tmp/project")
    }

    /// ST-terminated OSC 7 sequences carrying plain directory paths must correctly record the working directory state.
    func testSettingWorkingDirectoryWithOSC7ParsesPlainPathWithSTTerminator() {
        let terminal = self.terminal()
        send("\u{1B}]7;file:///var/log\u{1B}\\", to: terminal)
        send("\u{1B}]133;A\u{1B}\\\u{1B}]133;B\u{1B}\\ls\u{1B}]133;C\u{1B}\\\u{1B}]133;D;exit=0\u{1B}\\", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.commandRegions.last?.workingDirectory, "/var/log")
    }

    // MARK: - 6. OSC 8 Hyperlinks

    /// Terminal applications emit OSC 8 hyperlink opening and closing sequences to mark text as clickable links; cells after the close tag must not inherit link attributes.
    func testOpeningAndClosingHyperlinkAppliesLinkOnlyToIntermediateCells() {
        let terminal = self.terminal()
        send("\u{1B}]8;id=link1;https://example.com\u{07}linked\u{1B}]8;;\u{07}unlinked", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertNotNil(snapshot.rows[0][0].attributes.hyperlinkID)
        XCTAssertNil(snapshot.rows[0][6].attributes.hyperlinkID)
    }

    /// ST-terminated OSC 8 hyperlink sequences must attach URI metadata to intermediate cells and clear them when closed.
    func testOpeningAndClosingHyperlinkWithSTTerminatorAppliesToCells() {
        let terminal = self.terminal()
        send("\u{1B}]8;id=doc;https://allward.app\u{1B}\\doc\u{1B}]8;;\u{1B}\\plain", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertNotNil(snapshot.rows[0][0].attributes.hyperlinkID)
        XCTAssertNil(snapshot.rows[0][3].attributes.hyperlinkID)
    }

    // MARK: - 7. OSC 9 and OSC 777 Desktop Notifications

    /// CLI tools send OSC 9 notifications on command completion; payload text must be captured out-of-band and never printed onto grid cells.
    func testOSC9DesktopNotificationIsRecordedAndNotPrintedToScreen() {
        let terminal = self.terminal()
        send("\u{1B}]9;Build Finished Successfully\u{07}Normal Text", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertFalse(snapshot.plainText(row: 0).contains("Build Finished"))
        XCTAssertTrue(snapshot.plainText(row: 0).contains("Normal Text"))
    }

    /// rxvt-style OSC 777 notification messages must be swallowed into system notifications without corrupting terminal grid content.
    func testOSC777DesktopNotificationIsRecordedAndNotPrintedToScreen() {
        let terminal = self.terminal()
        send("\u{1B}]777;notify;Task Complete;All steps done\u{1B}\\Normal Text", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertFalse(snapshot.plainText(row: 0).contains("notify"))
        XCTAssertFalse(snapshot.plainText(row: 0).contains("Task Complete"))
        XCTAssertTrue(snapshot.plainText(row: 0).contains("Normal Text"))
    }

    // MARK: - 8. OSC 52 Clipboard Handling

    /// Utilities send base64-encoded strings via OSC 52 to set clipboard contents.
    func testOSC52ClipboardWriteDecodesBase64AndStoresContent() {
        let terminal = self.terminal()
        send("\u{1B}]52;c;SGVsbG8gV29ybGQ=\u{07}", to: terminal)
        XCTAssertTrue(terminal.pendingResponses.isEmpty)
    }

    /// Untrusted processes or remote SSH sessions query clipboard contents with `OSC 52 ; c ; ?`; returning clipboard data by default poses a severe security risk.
    func testOSC52ClipboardReadRequestIsIgnoredByDefaultToPreventSecurityLeak() {
        let terminal = self.terminal()
        send("\u{1B}]52;c;?\u{1B}\\", to: terminal)
        XCTAssertTrue(terminal.pendingResponses.isEmpty)
    }

    // MARK: - 9. OSC 133 Shell Integration Markers

    /// Shell integration scripts send OSC 133 prompt (`A`), command (`B`), execution (`C`), and completion (`D;exit=N`) markers to form distinct command regions.
    func testOSC133ShellIntegrationSequenceProducesCommandRegionWithExitCode() {
        let terminal = self.terminal()
        send("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo hi\u{1B}]133;C\u{07}hi\r\n\u{1B}]133;D;exit=42\u{07}", to: terminal)
        let snapshot = terminal.snapshot()
        let region = snapshot.commandRegions.last
        XCTAssertEqual(region?.exitCode, 42)
        XCTAssertEqual(region?.commandText, "echo hi")
    }

    /// ST-terminated OSC 133 sequences without explicit exit code key-value pairs must still construct valid command regions.
    func testOSC133FinishedMarkerWithoutExitCodeProducesCommandRegion() {
        let terminal = self.terminal()
        send("\u{1B}]133;A\u{1B}\\\u{1B}]133;B\u{1B}\\pwd\u{1B}]133;C\u{1B}\\\u{1B}]133;D\u{1B}\\", to: terminal)
        let snapshot = terminal.snapshot()
        XCTAssertNotNil(snapshot.commandRegions.last)
        XCTAssertEqual(snapshot.commandRegions.last?.commandText, "pwd")
    }

    // MARK: - 10. Robustness & Parser Resynchronization

    /// Unknown or unsupported OSC command numbers must be discarded safely without crashing the parser or preventing subsequent text output.
    func testUnknownOSCCommandNumberDoesNotCrashAndResynchronizes() {
        let terminal = self.terminal()
        send("\u{1B}]99999;unknown payload\u{07}OK", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
    }

    /// Empty OSC sequence payloads (`OSC ; ST`) must be handled as no-ops without crashing or locking the state machine.
    func testEmptyOSCPayloadDoesNotCrashAndResynchronizes() {
        let terminal = self.terminal()
        send("\u{1B}];\u{07}OK", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
    }

    /// Non-numeric command numbers in OSC headers must be ignored safely without throwing exceptions or corrupting memory.
    func testNonNumericOSCCommandDoesNotCrashAndResynchronizes() {
        let terminal = self.terminal()
        send("\u{1B}]abc;x\u{1B}\\OK", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
    }

    /// An unterminated OSC string followed by CSI or line endings must resynchronize so printable text renders correctly afterwards.
    func testUnterminatedOSCFollowedByNormalTextResynchronizes() {
        let terminal = self.terminal()
        send("\u{1B}]2;Unterminated title\r\nOK", to: terminal)
        XCTAssertTrue(terminal.snapshot().plainText(row: 1).contains("OK"))
    }

    /// Corrupted binary streams or non-UTF8 bytes inside OSC sequence bodies must not trap the UTF-8 decoder or lock the parser.
    func testOSCPayloadContainingInvalidUTF8BytesDoesNotCrashAndResynchronizes() {
        let terminal = self.terminal()
        sendBytes([0x1B, 0x5D, 0x32, 0x3B, 0xFF, 0xFE, 0xFD, 0x07], to: terminal)
        send("OK", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
    }

    /// Large payloads (100KB+) sent via OSC must be bounded or safely ignored without exceeding internal buffer limits or crashing the engine.
    func testVeryLongOSCPayloadDoesNotCrashOrExhaustMemoryAndResynchronizes() {
        let terminal = self.terminal()
        let hugePayload = String(repeating: "A", count: 100_000)
        send("\u{1B}]2;\(hugePayload)\u{07}OK", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0), "OK")
    }
}
