import AppKit
import XCTest

@testable import AllwardChrome

/// The keys a Mac terminal is expected to answer to.
///
/// These were verified against `ghostty +list-keybinds --default` and the
/// published defaults of Terminal.app and iTerm2. They exist as a test because
/// a missing convention is invisible from the inside: the app works perfectly
/// for whoever built it and is broken in the first minute for everyone else.
/// A gap here should fail a build, not wait to be noticed.
final class ConventionTests: XCTestCase {
    private var installed: [String: KeyChord] {
        Dictionary(uniqueKeysWithValues: Shortcut.all.map { ($0.id, $0.chord) })
    }

    @MainActor
    func testTheUniversalTerminalKeysAreBound() {
        let expected: [(String, String)] = [
            ("edit.copy", "⌘C"),
            ("edit.paste", "⌘V"),
            ("edit.select-all", "⌘A"),
            ("session.new-tab", "⌘T"),
            ("window.new", "⌘N"),
            ("pane.close", "⌘W"),
            ("window.close", "⇧⌘W"),
            ("tab.close", "⌥⌘W"),
            ("terminal.clear", "⌘K"),
            ("surface.settings", "⌘,"),
            ("font.increase", "⌘+"),
            ("font.decrease", "⌘-"),
            ("font.reset", "⌘0"),
            ("find.open", "⌘F"),
            ("find.next", "⌘G"),
            ("find.previous", "⇧⌘G"),
        ]
        for (id, label) in expected {
            guard let chord = installed[id] else {
                return XCTFail("\(id) is not bound; every Mac terminal binds \(label)")
            }
            XCTAssertEqual(chord.display, label, "\(id) should be \(label)")
        }
    }

    @MainActor
    func testEveryTabIsReachableByNumber() {
        // Command-1 through Command-8 pick a tab and Command-9 the last one, in
        // Safari, Chrome, Terminal.app, iTerm and Ghostty alike.
        for index in 1 ... 9 {
            guard let chord = installed["tab.select-\(index)"] else {
                return XCTFail("Command-\(index) does not select a tab")
            }
            XCTAssertEqual(chord.display, "⌘\(index)")
        }
    }

    @MainActor
    func testScrollbackAndPromptNavigationAreBound() {
        for id in [
            "scroll.top", "scroll.bottom", "scroll.page-up", "scroll.page-down",
            "prompt.previous", "prompt.next",
        ] {
            XCTAssertNotNil(installed[id], "\(id) is not bound")
        }
    }

    @MainActor
    func testCommandKBelongsToTheShellNotTheApp() {
        // Terminal.app, iTerm and Ghostty all clear the screen with Command-K.
        // The palette took the editor convention rather than shadowing it.
        XCTAssertEqual(Shortcut.clearScreen.display, "⌘K")
        XCTAssertEqual(Shortcut.palette.display, "⇧⌘P")
    }

    @MainActor
    func testEverySummonedSurfaceCanBeLeftByKeyboard() {
        // Escape reaches the responder chain, so no surface can trap the
        // keyboard even when SwiftUI focus is somewhere unexpected.
        XCTAssertTrue(
            MainWindowController.instancesRespond(to: #selector(NSResponder.cancelOperation(_:))),
            "Escape must be handled on the responder chain, not only in SwiftUI")
    }

    @MainActor
    func testMergeAllWindowsCanAppear() {
        // AppKit only injects the tab commands, including Merge All Windows,
        // into a window menu that exists.
        XCTAssertTrue(NSWindow.allowsAutomaticWindowTabbing)
    }
}
