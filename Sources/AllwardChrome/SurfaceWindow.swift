import AppKit

/// The window a summoned surface lives in.
///
/// Escape has to close that surface, and three attempts to make it do so
/// failed: `cancelOperation` on the responder chain, a SwiftUI `.onKeyPress`,
/// and a real first-responder fix. All three were correct and all three were
/// unreachable, because SwiftUI installs its own key view once the card
/// appears and consumes Escape before the responder chain is consulted.
///
/// `sendEvent` is the one place every key passes through on its way into the
/// window, whoever holds focus, so the decision is made here instead.
final class SurfaceWindow: NSWindow {
    /// Set while a summoned surface is up. Escape closes it; nothing else here
    /// touches the key stream.
    var dismissSummonedSurface: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
            dismissSummonedSurface?() == true
        {
            return
        }
        super.sendEvent(event)
    }
}
