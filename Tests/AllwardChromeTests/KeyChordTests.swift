import AppKit
import XCTest

@testable import AllwardChrome

/// The menu is the only place a key equivalent is installed, and every surface
/// renders its label from the same chord. These tests hold that seam shut.
final class KeyChordTests: XCTestCase {
    @MainActor
    func testModifiersReadInAppleOrder() {
        XCTAssertEqual(KeyChord("o", [.command, .shift]).display, "⇧⌘O")
        XCTAssertEqual(KeyChord("d", [.command]).display, "⌘D")
        XCTAssertEqual(KeyChord("\u{F702}", [.command, .option]).display, "⌥⌘←")
        XCTAssertEqual(KeyChord("\u{0009}", [.control, .shift]).display, "⌃⇧⇥")
        XCTAssertEqual(KeyChord(",", [.command]).display, "⌘,")
    }

    @MainActor
    func testCommandAlwaysComesLast() {
        for (id, chord) in Shortcut.all where chord.modifiers.contains(.command) {
            let display = chord.display
            guard let commandIndex = display.firstIndex(of: "⌘") else {
                return XCTFail("\(id) claims Command but does not show it")
            }
            let modifiers = display[display.startIndex..<commandIndex]
            XCTAssertFalse(
                modifiers.isEmpty && display.count == 1,
                "\(id) rendered no key")
            for symbol in modifiers {
                XCTAssertTrue(
                    "⌃⌥⇧".contains(symbol),
                    "\(id) puts \(symbol) after Command; Apple order is ⌃⌥⇧⌘")
            }
        }
    }

    @MainActor
    func testNoTwoCommandsClaimTheSameChord() {
        var seen: [String: String] = [:]
        for (id, chord) in Shortcut.all {
            let key = "\(chord.key)|\(chord.modifiers.rawValue)"
            if let owner = seen[key] {
                XCTFail("\(id) and \(owner) both bind \(chord.display)")
            }
            seen[key] = id
        }
    }

    @MainActor
    func testAdvertisedLabelsComeFromInstalledChords() {
        // A surface may only advertise a shortcut the registry installs.
        let installed = Set(Shortcut.all.map(\.chord.display))
        let advertised = [
            Shortcut.newTab.display, Shortcut.newWindow.display, Shortcut.closePane.display,
            Shortcut.splitRight.display, Shortcut.splitDown.display,
            Shortcut.connectSSH.display, Shortcut.board.display,
            Shortcut.digest.display, Shortcut.palette.display, Shortcut.rooms.display,
            Shortcut.teleport.display, Shortcut.settings.display,
        ]
        for label in advertised {
            XCTAssertTrue(installed.contains(label), "\(label) is advertised but never installed")
        }
    }

    @MainActor
    func testPaneFocusReadsAsOneGesture() {
        XCTAssertEqual(Shortcut.focusPane, "⌥⌘arrows")
        XCTAssertEqual(Shortcut.tabCycle, "⌃⇥ / ⌃⇧⇥")
    }
}

extension KeyChordTests {
    /// Prints the full registry so a reviewer can read the real labels rather
    /// than guess them from a screenshot.
    @MainActor
    func testRegistryLabelsAreStable() {
        let rendered = Shortcut.all.map { "\($0.id)=\($0.chord.display)" }.joined(separator: " ")
        print("SHORTCUTS \(rendered) pane.focus=\(Shortcut.focusPane) tabs=\(Shortcut.tabCycle)")
        XCTAssertEqual(Shortcut.connectSSH.display, "⇧⌘O")
        XCTAssertEqual(Shortcut.board.display, "⇧⌘B")
        XCTAssertEqual(Shortcut.splitDown.display, "⇧⌘D")
        XCTAssertEqual(Shortcut.settings.display, "⌘,")
    }
}
