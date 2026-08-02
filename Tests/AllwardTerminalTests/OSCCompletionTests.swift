import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

/// Tests verifying complete xterm OSC (Operating System Command) sequence handling.
///
/// Ensures full 10-19 dynamic colour coverage, consecutive-slot color parameters,
/// 110-119 resets, pointer shape setting, font set/query, title query via OSC 21,
/// clipboard read refusal / write recording, and metadata command handling.
final class OSCCompletionTests: XCTestCase {
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

    // MARK: - 1. Dynamic Colours (OSC 10-19) Set & Query

    /// Tests that every dynamic color slot in 10...19 can be set and queried individually.
    func testDynamicColorsRange10To19SetAndQuery() {
        let terminal = self.terminal()

        let slots: [(Int, DynamicColors.Slot)] = [
            (10, .foreground),
            (11, .background),
            (12, .cursor),
            (13, .pointerForeground),
            (14, .pointerBackground),
            (15, .tektronixForeground),
            (16, .tektronixBackground),
            (17, .highlightBackground),
            (18, .tektronixCursor),
            (19, .highlightForeground),
        ]

        for (commandNum, slot) in slots {
            send("\u{1B}]\(commandNum);#123456\u{07}", to: terminal)
            XCTAssertEqual(terminal.dynamicColors[slot], DynamicColors.RGB(0x12, 0x34, 0x56))

            send("\u{1B}]\(commandNum);?\u{07}", to: terminal)
            let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
            XCTAssertTrue(
                response.contains("\u{1B}]\(commandNum);rgb:1212/3434/5656\u{07}"),
                "Expected response for slot \(commandNum), got: \(response)"
            )
        }
    }

    // MARK: - 2. Consecutive-slot Semantics (OSC 10-19)

    /// OSC 10;#fff;#000 ST sets foreground (slot 10) to white and background (slot 11) to black.
    func testConsecutiveSlotSemanticsSetMultipleColorsInOneCommand() {
        let terminal = self.terminal()

        send("\u{1B}]10;#ffffff;#000000;#ff0000\u{1B}\\", to: terminal)

        XCTAssertEqual(terminal.dynamicColors[.foreground], DynamicColors.RGB(0xff, 0xff, 0xff))
        XCTAssertEqual(terminal.dynamicColors[.background], DynamicColors.RGB(0x00, 0x00, 0x00))
        XCTAssertEqual(terminal.dynamicColors[.cursor], DynamicColors.RGB(0xff, 0x00, 0x00))
    }

    /// OSC 10;?;?;? ST queries slots 10, 11, and 12 in a single command.
    func testConsecutiveSlotSemanticsQueryMultipleSlotsInOneCommand() {
        let terminal = self.terminal()

        send("\u{1B}]10;?;?;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)

        XCTAssertTrue(response.contains("\u{1B}]10;"), "Response should contain slot 10 reply")
        XCTAssertTrue(response.contains("\u{1B}]11;"), "Response should contain slot 11 reply")
        XCTAssertTrue(response.contains("\u{1B}]12;"), "Response should contain slot 12 reply")
    }

    /// OSC 13;... sets consecutive slots 13 through 19.
    func testConsecutiveSlotSemanticsExtendedSlots() {
        let terminal = self.terminal()

        send("\u{1B}]13;#111111;#222222;#333333;#444444;#555555;#666666;#777777\u{07}", to: terminal)

        XCTAssertEqual(terminal.dynamicColors[.pointerForeground], DynamicColors.RGB(0x11, 0x11, 0x11))
        XCTAssertEqual(terminal.dynamicColors[.pointerBackground], DynamicColors.RGB(0x22, 0x22, 0x22))
        XCTAssertEqual(terminal.dynamicColors[.tektronixForeground], DynamicColors.RGB(0x33, 0x33, 0x33))
        XCTAssertEqual(terminal.dynamicColors[.tektronixBackground], DynamicColors.RGB(0x44, 0x44, 0x44))
        XCTAssertEqual(terminal.dynamicColors[.highlightBackground], DynamicColors.RGB(0x55, 0x55, 0x55))
        XCTAssertEqual(terminal.dynamicColors[.tektronixCursor], DynamicColors.RGB(0x66, 0x66, 0x66))
        XCTAssertEqual(terminal.dynamicColors[.highlightForeground], DynamicColors.RGB(0x77, 0x77, 0x77))
    }

    // MARK: - 3. Dynamic Colour Resets (OSC 110-119)

    /// OSC 110-119 resets dynamic color slots 10-19 back to theme defaults.
    func testDynamicColorResets110To119() {
        let terminal = self.terminal()

        for slotNum in 10...19 {
            let resetCmd = slotNum + 100
            let slot = DynamicColors.Slot(rawValue: slotNum)!

            send("\u{1B}]\(slotNum);#ff0000\u{07}", to: terminal)
            XCTAssertEqual(terminal.dynamicColors[slot], DynamicColors.RGB(0xff, 0x00, 0x00))

            send("\u{1B}]\(resetCmd)\u{07}", to: terminal)
            XCTAssertNotEqual(terminal.dynamicColors[slot], DynamicColors.RGB(0xff, 0x00, 0x00))
        }
    }

    /// OSC 110;; ST resets consecutive slots starting at 10.
    func testConsecutiveDynamicColorResets() {
        let terminal = self.terminal()

        send("\u{1B}]10;#aaaaaa;#bbbbbb\u{07}", to: terminal)
        XCTAssertEqual(terminal.dynamicColors[.foreground], DynamicColors.RGB(0xaa, 0xaa, 0xaa))
        XCTAssertEqual(terminal.dynamicColors[.background], DynamicColors.RGB(0xbb, 0xbb, 0xbb))

        send("\u{1B}]110;;\u{07}", to: terminal)
        XCTAssertNotEqual(terminal.dynamicColors[.foreground], DynamicColors.RGB(0xaa, 0xaa, 0xaa))
        XCTAssertNotEqual(terminal.dynamicColors[.background], DynamicColors.RGB(0xbb, 0xbb, 0xbb))
    }

    // MARK: - 4. OSC 46 Security & Logfile Protection

    /// OSC 46 (logfile name change) must never create or write to a file under any circumstances.
    func testOSC46LogfileCommandWritesNothingAndDoesNotCreateFiles() {
        let terminal = self.terminal()
        let targetPath = "/tmp/allward_test_logfile_should_not_exist_\(UUID().uuidString).txt"

        // Ensure target does not exist beforehand
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath))

        // Send hostile OSC 46 payload targeting path
        send("\u{1B}]46;\(targetPath)\u{07}", to: terminal)

        // Ensure no file was created
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath))

        // Verify terminal engine state and subsequent text output remain clean
        send("Hello World", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0).trimmingCharacters(in: .whitespaces), "Hello World")
    }

    // MARK: - 5. OSC 3 & Special Colors (5, 105, 106)

    /// OSC 3 and special colors update state without producing printable output.
    func testOSC3AndSpecialColorsAreRecordedSafely() {
        let terminal = self.terminal()

        send("\u{1B}]3;prop=value\u{07}", to: terminal)
        send("\u{1B}]5;0;#ffffff\u{1B}\\", to: terminal)
        send("\u{1B}]105;0\u{07}", to: terminal)
        send("\u{1B}]106;0;1\u{1B}\\", to: terminal)

        XCTAssertTrue(terminal.pendingResponses.isEmpty)
        send("Safe", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0).trimmingCharacters(in: .whitespaces), "Safe")
    }

    // MARK: - 6. OSC 22 Pointer Shape

    /// OSC 22 sets mouse pointer shape name and clears it when empty.
    func testOSC22PointerShapeSetAndReset() {
        let terminal = self.terminal()

        send("\u{1B}]22;ibeam\u{07}", to: terminal)
        XCTAssertEqual(terminal.pointerShape, "ibeam")

        // Unknown cursor shape name must be recorded safely without trapping
        send("\u{1B}]22;custom_nonexistent_cursor_123\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.pointerShape, "custom_nonexistent_cursor_123")

        // Empty argument resets pointer shape
        send("\u{1B}]22;\u{07}", to: terminal)
        XCTAssertNil(terminal.pointerShape)
    }

    // MARK: - 7. OSC 50 Font Set & Query

    /// OSC 50 reports configured font name when queried and records setting font.
    func testOSC50FontSetAndQuery() {
        let terminal = self.terminal()

        // Query default font
        send("\u{1B}]50;?\u{07}", to: terminal)
        let response1 = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(response1, "\u{1B}]50;Menlo\u{07}")

        // Set font
        send("\u{1B}]50;Fira Code\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.fontName, "Fira Code")

        // Query updated font with ST terminator
        send("\u{1B}]50;?\u{1B}\\", to: terminal)
        let response2 = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(response2, "\u{1B}]50;Fira Code\u{1B}\\")
    }

    // MARK: - 8. OSC 21 Title Reporting & Setting

    /// OSC 21 queries window title when given `?` and sets title when given text.
    func testOSC21TitleSetAndQuery() {
        let terminal = self.terminal()

        // Set title via OSC 2
        send("\u{1B}]2;My Shell Title\u{07}", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "My Shell Title")

        // Query title via OSC 21
        send("\u{1B}]21;?\u{07}", to: terminal)
        let response = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertEqual(response, "\u{1B}]21;My Shell Title\u{07}")

        // Set title via OSC 21
        send("\u{1B}]21;New Title via 21\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.snapshot().title, "New Title via 21")
    }

    // MARK: - 9. OSC 52 Clipboard Handling

    /// OSC 52 records writes, refuses reads, and supports both `c` and `p` selections.
    func testOSC52ClipboardWritesAndReadRefusals() {
        let terminal = self.terminal()

        // Write to clipboard `c`
        send("\u{1B}]52;c;SGVsbG8=\u{07}", to: terminal)
        XCTAssertEqual(terminal.clipboardWrites.count, 1)
        XCTAssertEqual(terminal.clipboardWrites.first?.selection, "c")
        XCTAssertEqual(terminal.clipboardWrites.first?.base64, "SGVsbG8=")

        // Write to primary selection `p`
        send("\u{1B}]52;p;V29ybGQ=\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.clipboardWrites.count, 2)
        XCTAssertEqual(terminal.clipboardWrites[1].selection, "p")
        XCTAssertEqual(terminal.clipboardWrites[1].base64, "V29ybGQ=")

        // Read query `c` refused
        send("\u{1B}]52;c;?\u{07}", to: terminal)
        XCTAssertEqual(terminal.clipboardReadsRefused, 1)

        // Read query `p` refused
        send("\u{1B}]52;p;?\u{1B}\\", to: terminal)
        XCTAssertEqual(terminal.clipboardReadsRefused, 2)

        // Read query `cp` refused
        send("\u{1B}]52;cp;?\u{07}", to: terminal)
        XCTAssertEqual(terminal.clipboardReadsRefused, 3)

        // Ensure no data was sent back into pendingResponses on read refusal
        XCTAssertTrue(terminal.pendingResponses.isEmpty)
    }

    // MARK: - 10. Terminator Matching (BEL vs ST)

    /// Terminal matches the requester's string terminator (BEL vs ST) in response payloads.
    func testTerminatorMatchingInResponses() {
        let terminal = self.terminal()

        // BEL terminator -> BEL response
        send("\u{1B}]10;?\u{07}", to: terminal)
        let belResp = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(belResp.hasSuffix("\u{07}"))

        // ST terminator -> ST response
        send("\u{1B}]10;?\u{1B}\\", to: terminal)
        let stResp = String(decoding: terminal.pendingResponses, as: UTF8.self)
        XCTAssertTrue(stResp.hasSuffix("\u{1B}\\"))
    }

    // MARK: - 11. Defined OSC sequences remain side-effect free for the grid

    /// Defined metadata OSC commands update terminal state without corrupting printable text.
    func testDefinedMetadataOSCSequencesDoNotCorruptTerminal() {
        let terminal = self.terminal()

        send("\u{1B}]30;fontname\u{07}", to: terminal)
        send("\u{1B}]31;fontname\u{1B}\\", to: terminal)
        send("\u{1B}]51;emacs\u{07}", to: terminal)
        send("\u{1B}]60;graphics\u{1B}\\", to: terminal)
        send("\u{1B}]1337;File=inline=1:SGVsbG8=\u{07}", to: terminal)
        send("\u{1B}]9999;unknown_payload\u{1B}\\", to: terminal)

        XCTAssertEqual(
            String(decoding: terminal.pendingResponses, as: UTF8.self),
            "\u{1B}]60;\u{1B}\\"
        )

        send("Functional Text", to: terminal)
        XCTAssertEqual(terminal.snapshot().plainText(row: 0).trimmingCharacters(in: .whitespaces), "Functional Text")
    }
}
