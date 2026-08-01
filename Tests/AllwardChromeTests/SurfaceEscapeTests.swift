import AppKit
import XCTest

@testable import AllwardChrome

/// Escape closes a summoned surface before anything else sees the key.
///
/// This shipped broken three times. Each fix was placed somewhere in the
/// responder chain - `cancelOperation`, a SwiftUI `.onKeyPress`, a first
/// responder correction - and each was correct and unreachable, because
/// SwiftUI installs its own key view over the card and consumes Escape first.
/// A focused text field does the same thing: its field editor takes Escape to
/// cancel editing.
///
/// The GUI harness could never catch it. Under `--capture` the application is
/// never key, so SwiftUI focus never truly engages and the responder chain
/// happens to work - the one state in which the bug does not exist. So the
/// guarantee is asserted here, on the interception itself: the key is taken at
/// `NSWindow.sendEvent`, which every key passes through on its way in, before
/// any responder is consulted.
final class SurfaceEscapeTests: XCTestCase {
    private func escapeEvent(in window: NSWindow, modifiers: NSEvent.ModifierFlags = [])
        -> NSEvent
    {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
    }

    private func makeWindow() -> SurfaceWindow {
        SurfaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true)
    }

    @MainActor
    func testEscapeIsTakenBeforeAnyResponderSeesIt() {
        let window = makeWindow()
        var dismissed = false
        window.dismissSummonedSurface = {
            dismissed = true
            return true
        }
        window.sendEvent(escapeEvent(in: window))
        XCTAssertTrue(
            dismissed,
            "Escape must close a summoned surface at the window, not from the "
                + "responder chain - whatever holds focus consumes it there.")
    }

    /// With no surface up, Escape is the terminal's: programs read it.
    @MainActor
    func testEscapePassesThroughWithNoSurface() {
        let window = makeWindow()
        var asked = false
        window.dismissSummonedSurface = {
            asked = true
            return false
        }
        window.sendEvent(escapeEvent(in: window))
        XCTAssertTrue(asked, "The window must ask whether a surface is up.")
    }

    /// Only a bare Escape closes a surface; the modified chords belong to
    /// whatever binds them.
    @MainActor
    func testModifiedEscapeIsNotADismissal() {
        let window = makeWindow()
        var dismissed = false
        window.dismissSummonedSurface = {
            dismissed = true
            return true
        }
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control] {
            window.sendEvent(escapeEvent(in: window, modifiers: modifier))
        }
        XCTAssertFalse(dismissed, "A modified Escape is a different key.")
    }
}
