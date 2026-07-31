import AppKit

/// Every key equivalent the app advertises, defined exactly once.
///
/// The menu installs these as real `NSMenuItem` key equivalents, and the
/// palette and settings render their labels from the same values.
/// An advertised shortcut therefore cannot describe a binding that does not
/// exist, and a label cannot drift from the key that actually fires.
///
/// Labels follow the Apple ordering for modifiers, Control, Option, Shift then
/// Command, which is the order a Mac user reads them in every other app.
public struct KeyChord: Hashable, Sendable {
    /// The key equivalent as AppKit wants it: lowercase letters, or a function
    /// key sentinel for the arrows and tab.
    public let key: String
    private let modifierMask: UInt

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierMask) }

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifierMask = modifiers.rawValue
    }

    /// The user-facing label, in Apple's modifier order.
    public var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + Self.symbol(for: key)
    }

    private static func symbol(for key: String) -> String {
        switch key {
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\u{0009}": return "⇥"
        case "\u{F729}": return "↖"
        case "\u{F72B}": return "↘"
        case "\u{F72C}": return "⇞"
        case "\u{F72D}": return "⇟"
        default: return key.uppercased()
        }
    }
}

/// The command identities the menu, palette and settings all share.
public enum Shortcut {
    public static let newTab = KeyChord("t", [.command])
    public static let newLocalTerminal = KeyChord("t", [.command, .option])
    public static let newWindow = KeyChord("n", [.command])
    public static let connectSSH = KeyChord("o", [.command, .shift])
    public static let closePane = KeyChord("w", [.command])
    public static let closeTab = KeyChord("w", [.command, .option])
    public static let splitRight = KeyChord("d", [.command])
    public static let splitDown = KeyChord("d", [.command, .shift])
    public static let focusLeft = KeyChord("\u{F702}", [.command, .option])
    public static let focusRight = KeyChord("\u{F703}", [.command, .option])
    public static let focusUp = KeyChord("\u{F700}", [.command, .option])
    public static let focusDown = KeyChord("\u{F701}", [.command, .option])
    public static let nextTab = KeyChord("\u{0009}", [.control])
    public static let previousTab = KeyChord("\u{0009}", [.control, .shift])
    public static let board = KeyChord("b", [.command, .shift])
    public static let router = KeyChord("r", [.command, .shift])
    public static let digest = KeyChord("e", [.command, .shift])
    /// Command-K clears the screen in Terminal.app, iTerm and Ghostty, so the
    /// palette takes the editor convention instead of stealing it.
    public static let palette = KeyChord("p", [.command, .shift])
    public static let rooms = KeyChord("m", [.command, .shift])
    public static let teleport = KeyChord("t", [.command, .shift])
    public static let settings = KeyChord(",", [.command])
    public static let closeWindow = KeyChord("w", [.command, .shift])
    public static let copy = KeyChord("c", [.command])
    public static let paste = KeyChord("v", [.command])
    public static let selectAll = KeyChord("a", [.command])
    public static let clearScreen = KeyChord("k", [.command])
    public static let increaseFontSize = KeyChord("+", [.command])
    public static let decreaseFontSize = KeyChord("-", [.command])
    public static let resetFontSize = KeyChord("0", [.command])
    public static let scrollPageUp = KeyChord("\u{F72C}", [.command])
    public static let scrollPageDown = KeyChord("\u{F72D}", [.command])
    public static let scrollToTop = KeyChord("\u{F729}", [.command])
    public static let scrollToBottom = KeyChord("\u{F72B}", [.command])
    public static let previousPrompt = KeyChord("\u{F700}", [.command, .shift])
    public static let nextPrompt = KeyChord("\u{F701}", [.command, .shift])

    /// Command-1 through Command-8 select a tab and Command-9 the last one,
    /// which is what every browser and every other terminal does.
    public static func selectTab(_ index: Int) -> KeyChord {
        KeyChord("\(index)", [.command])
    }

    /// Pane focus is four bindings a user thinks of as one gesture.
    public static var focusPane: String { "\(focusLeft.display.dropLast())arrows" }

    /// Tab cycling is a pair, and the settings list shows it as one row.
    public static var tabCycle: String { "\(nextTab.display) / \(previousTab.display)" }

    /// Every chord the menu installs, so a test can prove the advertised labels
    /// and the installed key equivalents are the same set.
    public static let all: [(id: String, chord: KeyChord)] = [
        ("session.new-tab", newTab),
        ("session.new-local", newLocalTerminal),
        ("window.new", newWindow),
        ("host.connect", connectSSH),
        ("pane.close", closePane),
        ("tab.close", closeTab),
        ("pane.split-right", splitRight),
        ("pane.split-down", splitDown),
        ("pane.focus-left", focusLeft),
        ("pane.focus-right", focusRight),
        ("pane.focus-up", focusUp),
        ("pane.focus-down", focusDown),
        ("tab.next", nextTab),
        ("tab.previous", previousTab),
        ("surface.board", board),
        ("surface.router", router),
        ("surface.digest", digest),
        ("surface.palette", palette),
        ("surface.rooms", rooms),
        ("surface.teleport", teleport),
        ("surface.settings", settings),
        ("window.close", closeWindow),
        ("edit.copy", copy),
        ("edit.paste", paste),
        ("edit.select-all", selectAll),
        ("terminal.clear", clearScreen),
        ("font.increase", increaseFontSize),
        ("font.decrease", decreaseFontSize),
        ("font.reset", resetFontSize),
        ("scroll.page-up", scrollPageUp),
        ("scroll.page-down", scrollPageDown),
        ("scroll.top", scrollToTop),
        ("scroll.bottom", scrollToBottom),
        ("prompt.previous", previousPrompt),
        ("prompt.next", nextPrompt),
    ] + (1 ... 9).map { ("tab.select-\($0)", selectTab($0)) }
}
