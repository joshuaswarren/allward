import AllwardCore
import Foundation
import XCTest

@testable import AllwardTerminal

final class OSCFullCoverageTests: XCTestCase {
    private func terminal(
        allowLogFile: Bool = false,
        allowClipboardRead: Bool = false
    ) -> Terminal {
        Terminal(
            geometry: TerminalGeometry(columns: 80, rows: 24),
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            scrollbackCapacity: 1000,
            allowLogFile: allowLogFile,
            allowClipboardRead: allowClipboardRead
        )
    }

    private func send(_ text: String, to terminal: Terminal) {
        terminal.consume(ArraySlice(Array(text.utf8)))
    }

    func testOSC3RecordsXProperty() {
        let terminal = terminal()
        send("\u{1B}]3;WM_CLASS;allward\u{07}", to: terminal)
        XCTAssertEqual(terminal.xProperties["WM_CLASS"], "allward")
    }

    func testSpecialColorsSetQueryAndReset() {
        let terminal = terminal()
        send("\u{1B}]5;0;#112233\u{07}", to: terminal)
        XCTAssertEqual(terminal.specialColors[0], "#112233")

        send("\u{1B}]5;0;?\u{07}", to: terminal)
        XCTAssertEqual(
            String(decoding: terminal.pendingResponses, as: UTF8.self),
            "\u{1B}]5;0;#112233\u{07}"
        )

        send("\u{1B}]105;0\u{07}", to: terminal)
        XCTAssertNil(terminal.specialColors[0])
    }

    func testOSC6RecordsColorModeAndOSC106UpdatesIt() {
        let terminal = terminal()
        send("\u{1B}]6;2;1;3;0\u{07}", to: terminal)
        XCTAssertEqual(terminal.colorModes[2], true)
        XCTAssertEqual(terminal.colorModes[3], false)

        send("\u{1B}]106;2;0\u{07}", to: terminal)
        XCTAssertEqual(terminal.colorModes[2], false)
    }

    func testKonsoleTabTitleAndIconAreRecorded() {
        let terminal = terminal()
        send("\u{1B}]30;Build\u{07}", to: terminal)
        send("\u{1B}]31;build.icns\u{07}", to: terminal)
        XCTAssertEqual(terminal.tabTitle, "Build")
        XCTAssertEqual(terminal.tabIcon, "build.icns")
        XCTAssertEqual(terminal.snapshot().title, "Build")
    }

    func testOSC51RecordsEmacsPromptMarker() {
        let terminal = terminal()
        send("\u{1B}]51;prompt-start\u{07}", to: terminal)
        XCTAssertEqual(terminal.emacsPromptMarker, "prompt-start")
    }

    func testOSC60ReportsNoOptionalFeatureCategories() {
        let terminal = terminal()
        send("\u{1B}]60;?\u{1B}\\", to: terminal)
        XCTAssertEqual(
            String(decoding: terminal.pendingResponses, as: UTF8.self),
            "\u{1B}]60;\u{1B}\\"
        )
    }

    func testITermUsefulMembersAndFilePayload() {
        let terminal = terminal()
        send("\u{1B}]1337;SetUserVar=project=cHJvamVjdA==\u{07}", to: terminal)
        send("\u{1B}]1337;CurrentDir=/tmp/project\u{07}", to: terminal)
        send("\u{1B}]1337;ShellIntegrationVersion=1\u{07}", to: terminal)
        send("\u{1B}]1337;RemoteHost=user%40host\u{07}", to: terminal)
        send("\u{1B}]1337;File=name=test.png:inline=1:iVBORw0KGgo=\u{07}", to: terminal)

        XCTAssertEqual(terminal.itermUserVariables["project"], "project")
        XCTAssertEqual(terminal.itermCurrentDirectory, "/tmp/project")
        XCTAssertEqual(terminal.itermShellIntegrationVersion, "1")
        XCTAssertEqual(terminal.itermRemoteHost, "user%40host")
        XCTAssertEqual(terminal.itermFilesConsumed, 1)
        send("visible", to: terminal)
        XCTAssertEqual(
            terminal.snapshot().plainText(row: 0).trimmingCharacters(in: .whitespaces),
            "visible"
        )
    }

    func testOSC46DoesNotTouchFilesByDefault() {
        let path = "/tmp/allward-osc46-off-\(UUID().uuidString)"
        let terminal = terminal()
        send("\u{1B}]46;\(path)\u{07}", to: terminal)
        send("text", to: terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOSC46WritesOutputWhenEnabled() throws {
        let path = "/tmp/allward-osc46-on-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let terminal = terminal(allowLogFile: true)
        send("\u{1B}]46;\(path)\u{07}logged", to: terminal)
        XCTAssertEqual(try String(contentsOfFile: path), "logged")
    }

    func testOSC52ReadIsRefusedByDefault() {
        let terminal = terminal()
        send("\u{1B}]52;c;?\u{07}", to: terminal)
        XCTAssertTrue(terminal.pendingResponses.isEmpty)
        XCTAssertEqual(terminal.clipboardReadsRefused, 1)
    }

    func testOSC52ReadsClipboardWhenEnabled() {
        let terminal = terminal(allowClipboardRead: true)
        terminal.clipboardText = "secret"
        send("\u{1B}]52;c;?\u{1B}\\", to: terminal)
        XCTAssertEqual(
            String(decoding: terminal.pendingResponses, as: UTF8.self),
            "\u{1B}]52;c;c2VjcmV0\u{1B}\\"
        )
        XCTAssertEqual(terminal.clipboardReadsRefused, 0)
    }
}
