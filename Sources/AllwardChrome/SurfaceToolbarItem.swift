import AppKit

/// A toolbar button that explains itself and knows when it cannot act.
///
/// Two faults it exists to fix. The toolbar is icon-only, and setting
/// `NSToolbarItem.toolTip` alone did not put a tooltip on screen - the value
/// was there on every item and no tooltip ever appeared, because the item was
/// forwarding to a button it made itself. The button is ours now, so the
/// tooltip is too.
///
/// And Teleport, with nothing needing attention, ran and did nothing. A control
/// that accepts a click and produces no result reads as broken. It goes dim
/// instead, and says why.
final class SurfaceToolbarItem: NSToolbarItem {
    private let button: NSButton
    private let help: String
    private let unavailableHelp: String?

    /// Whether the command can do anything right now. Checked on every
    /// validation pass, which AppKit runs as the window state changes.
    var isAvailable: () -> Bool = { true }

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        help: String,
        unavailableHelp: String?,
        action: Selector
    ) {
        self.help = help
        self.unavailableHelp = unavailableHelp
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button = NSButton(image: image ?? NSImage(), target: nil, action: action)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        super.init(itemIdentifier: itemIdentifier)
        self.label = label
        self.paletteLabel = label
        self.toolTip = help
        button.toolTip = help
        self.view = button
        self.action = action
        self.target = nil
    }

    override func validate() {
        let available = isAvailable()
        isEnabled = available
        button.isEnabled = available
        let tip = available ? help : (unavailableHelp ?? help)
        toolTip = tip
        button.toolTip = tip
    }
}
