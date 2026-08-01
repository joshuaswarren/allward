import AllwardCore
import AllwardDesign
import AppKit
import SwiftUI

/// One window owns one Room and an ordered tab set. Chrome stays outside the
/// terminal `gridFrame`; summoned surfaces move focus explicitly and never sit
/// translucently over a live cursor (DESIGN-LANGUAGE §23.1).
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    private let splitHost: SplitHostView
    private let routerHost: NSHostingView<AnyView>
    private let overlayHost: NSHostingView<AnyView>
    private let roomSeam = NSView()
    private let seamPattern = CAShapeLayer()
    private var overlay: SummonedSurface?

    /// Which summoned surface is on screen. Exactly one at a time, so focus
    /// transfer and restoration stay unambiguous.
    public enum SummonedSurface: Equatable {
        case board
        case digest
        case commandPalette
        case settings
        case diagnostics
        case roomSwitcher
        case hostPicker
        case find
    }

    /// The tab this window is. Native tabbing makes a tab a real window, so
    /// the controller renders exactly one tab's pane tree.
    public let tab: TabID

    public init(model: AppModel, tab: TabID) {
        self.model = model
        self.tab = tab
        self.splitHost = SplitHostView(palette: model.palette)
        self.routerHost = NSHostingView(rootView: AnyView(EmptyView()))
        self.overlayHost = NSHostingView(rootView: AnyView(EmptyView()))

        let window = SurfaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Allward"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.tabbingMode = .preferred
        // Windows only group into one native tab bar when they agree on an
        // identifier. Keying it to the Room means tabs group the way the user
        // already thinks about their work.
        window.tabbingIdentifier =
            "allward.room.\(model.activeRoom.map { "\($0.id.rawValue)" } ?? "default")"
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("AllwardMainWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
        model.attach(window: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MainWindowController is code-only") }

    /// The plus button in the native tab bar, and Command-T when AppKit routes
    /// it here. Both must make an Allward tab, not a bare window.
    @objc public override func newWindowForTab(_ sender: Any?) {
        Task { await model.newTab() }
    }

    private func buildContent() {
        guard let window else { return }
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = model.terminalTheme.defaultBackground.cgColor

        splitHost.delegate = self
        roomSeam.wantsLayer = true
        seamPattern.isHidden = true
        roomSeam.layer?.addSublayer(seamPattern)
        overlayHost.isHidden = true

        root.addSubview(roomSeam)
        root.addSubview(splitHost)
        root.addSubview(routerHost)
        root.addSubview(overlayHost)
        root.onLayout = { [weak self] bounds in self?.layoutContent(in: bounds) }
        window.contentView = root
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        applyPalette()
    }

    private func layoutContent(in bounds: CGRect) {
        // The content view is full-size, so the titlebar and unified toolbar
        // sit above y=0 rather than beside it. Laying out from the top of the
        // view puts the tab strip, and the grid's first rows, underneath them.
        let topInset = max(0, bounds.height - (window?.contentLayoutRect.height ?? bounds.height))
        let seamWidth = StrokeToken.roomSeam.width(model.palette.settings)
        roomSeam.frame = CGRect(
            x: 0, y: topInset, width: seamWidth, height: bounds.height - topInset)
        applyRoomSeam()
        let contentX = seamWidth
        let contentWidth = bounds.width - seamWidth
        let routerHeight = routerHost.isHidden ? 0 : routerHost.fittingSize.height
        splitHost.frame = CGRect(
            x: contentX, y: topInset, width: contentWidth,
            height: max(0, bounds.height - topInset - routerHeight))
        routerHost.frame = CGRect(
            x: contentX, y: splitHost.frame.maxY, width: contentWidth, height: routerHeight)
        overlayHost.frame = CGRect(
            x: 0, y: topInset, width: bounds.width, height: bounds.height - topInset)
    }

    // MARK: Palette and topology

    public func paletteDidChange(_ palette: DesignPalette) {
        splitHost.palette = palette
        applyPalette()
        // A hosted surface captured the old palette when it was built, so an
        // accessibility change made while one is open would not reach it. Any
        // presented surface is rebuilt against the new palette.
        rebuildPresentedSurface()
    }

    /// The seam is the one place Room identity is carried by hue alone.
    ///
    /// With Differentiate Without Colour on, two Rooms whose tints a user
    /// cannot tell apart become the same seam. Giving each Room a stable dash
    /// pattern makes the seam readable by shape, so the cue survives without
    /// relying on the colour at all.
    private func applyRoomSeam() {
        let colour = model.palette[.seam].cgColor
        guard model.palette.settings.differentiateWithoutColor,
            let room = model.activeRoom?.id
        else {
            seamPattern.isHidden = true
            roomSeam.layer?.backgroundColor = colour
            return
        }
        roomSeam.layer?.backgroundColor = model.palette[.canvas].cgColor
        seamPattern.isHidden = false
        seamPattern.frame = roomSeam.bounds
        seamPattern.strokeColor = colour
        seamPattern.lineWidth = roomSeam.bounds.width
        seamPattern.lineDashPattern = Self.seamDashes(for: room)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: roomSeam.bounds.midX, y: 0))
        path.addLine(to: CGPoint(x: roomSeam.bounds.midX, y: roomSeam.bounds.height))
        seamPattern.path = path
    }

    /// A stable dash rhythm per Room, so the same Room always looks the same.
    static func seamDashes(for room: RoomID) -> [NSNumber] {
        let patterns: [[NSNumber]] = [
            [24, 0], [12, 6], [4, 4], [18, 4, 4, 4], [2, 6],
        ]
        var hash: UInt64 = 5381
        for byte in "\(room.rawValue)".utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return patterns[Int(hash % UInt64(patterns.count))]
    }

    private func rebuildPresentedSurface() {
        switch overlay {
        case .board: presentBoard()
        case .digest: presentDigest()
        case .commandPalette: presentCommandPalette()
        case .settings: presentSettings()
        case .diagnostics: presentDiagnostics()
        case .roomSwitcher: presentRoomSwitcher()
        case .hostPicker: presentHostPicker()
        case .find: presentFind()
        case .none: break
        }
    }

    private func applyPalette() {
        window?.contentView?.layer?.backgroundColor =
            model.terminalTheme.defaultBackground.cgColor
        applyRoomSeam()
        // The titlebar is transparent over the grid, so the system draws its
        // title text straight onto the session background. Taking the window's
        // appearance from the chrome palette meant a light-mode Mac painted
        // black text on a black terminal. It follows the grid instead.
        let onDarkGrid = model.terminalTheme.defaultBackground.relativeLuminance < 0.35
        window?.appearance = NSAppearance(named: onDarkGrid ? .darkAqua : .aqua)
        window?.contentView?.needsLayout = true
    }

    /// A new window must be typable immediately. Without this the first
    /// responder stays on a view that ignores keys, so the first keystroke
    /// beeps and vanishes until the grid is clicked.
    public func focusGrid() {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let pane = model.layout(for: tab)?.leaves.first,
            let view = model.paneView(for: pane), view.window === window
        else { return }
        window?.initialFirstResponder = view
        window?.makeFirstResponder(view)
    }

    public func topologyDidChange() {
        splitHost.setContainers(model.containers)
        splitHost.setLayout(model.layout(for: tab))
        // The native tab bar shows this title, so it names the session rather
        // than repeating the app name on every tab.
        window?.title = model.tabTitle(for: tab)
        window?.subtitle = model.activeRoom?.name ?? ""
        if let pane = model.focusedPane, let view = model.paneView(for: pane),
            view.window === window, window?.firstResponder !== view
        {
            window?.makeFirstResponder(view)
        }
        window?.contentView?.needsLayout = true
        // Layout may have only just attached the pane, so claim focus once the
        // hierarchy has settled rather than assuming it was ready above.
        DispatchQueue.main.async { [weak self] in
            guard let self, overlay == nil else { return }
            if window?.firstResponder is TerminalPaneView { return }
            focusGrid()
        }
    }

    // MARK: Window lifecycle

    /// Closing a tab's window closes the tab it stands for. Without this the
    /// window disappears while the session keeps running with nothing to show
    /// it, which is worse than either outcome on its own.
    public func windowWillClose(_ notification: Notification) {
        Task { [tab] in await model.closeTab(tab) }
    }

    /// The key window is the focused tab, so focus follows the tab bar.
    public func windowDidBecomeKey(_ notification: Notification) {
        if overlay == nil { focusGrid() }
        guard model.focusedTab != tab else { return }
        Task { [tab] in await model.focusTab(tab) }
    }

    /// Escape dismisses whatever is summoned, from anywhere.
    ///
    /// Each surface also handles Escape in SwiftUI, but that only fires when
    /// SwiftUI focus happens to be inside it, which is why Settings could be
    /// opened and not closed. This is the responder-chain backstop, so the
    /// keyboard is never a dead end.
    public override func cancelOperation(_ sender: Any?) {
        guard overlay != nil else { return }
        dismissSummonedSurface()
    }

    /// The router strip lives outside the grid frame and never takes focus.
    public func setRouterStrip<Content: View>(_ content: Content?) {
        if let content {
            routerHost.isHidden = false
            routerHost.rootView = AnyView(content.allwardPalette(model.palette))
        } else {
            routerHost.isHidden = true
        }
        window?.contentView?.needsLayout = true
    }

    // MARK: Summoned surfaces

    /// Presenting a surface suspends terminal input by moving first responder
    /// into the surface; dismissal restores the exact pane and input target.
    public func present<Content: View>(_ surface: SummonedSurface, content: Content) {
        overlay = surface
        overlayHost.isHidden = false
        let host = window?.contentView?.bounds.size ?? .zero
        overlayHost.rootView = AnyView(
            SummonedCard(
                maxHeight: host.height * Self.surfaceHeightShare,
                onEscape: { [weak self] in self?.dismissSummonedSurface() }
            ) { content }
                .allwardPalette(model.palette)
                .background(model.palette[.surfaceScrim].swiftUIColor)
        )
        window?.makeFirstResponder(overlayHost)
        surfaceWindow?.dismissSummonedSurface = { [weak self] in
            guard let self, self.overlay != nil else { return false }
            self.dismissSummonedSurface()
            return true
        }
    }

    private var surfaceWindow: SurfaceWindow? { window as? SurfaceWindow }

    /// A summoned surface is a card inside the window, so it must always read
    /// as smaller than the window it sits in. Each surface picks its own width;
    /// height is the axis that overflowed, so only height is capped.
    private static let surfaceHeightShare: CGFloat = 0.82

    public func dismissSummonedSurface() {
        guard overlay != nil else { return }
        overlay = nil
        overlayHost.isHidden = true
        overlayHost.rootView = AnyView(EmptyView())
        // Dismissing must hand the keyboard back to the grid. Falling through
        // to the split host leaves the window itself first responder, so the
        // next keystroke beeps exactly as it did before a pane was focused.
        if let pane = model.focusedPane, let view = model.paneView(for: pane),
            view.window === window
        {
            window?.makeFirstResponder(view)
        } else {
            focusGrid()
        }
    }

    /// The area panes are laid out in, so a shell can be started at the size
    /// it will actually occupy rather than a placeholder.
    public var paneHostSize: CGSize? {
        // Lay out from the content view: splitHost's own frame is set by its
        // superview, so laying out only its subtree leaves it at zero on the
        // first pass, before the window has ever been through layout.
        window?.contentView?.layoutSubtreeIfNeeded()
        let size = splitHost.bounds.size
        return size.width > 1 && size.height > 1 ? size : nil
    }

    /// Frames of the laid-out pane containers, for capture-mode diagnostics.
    public func layoutReport() -> String {
        let panes = splitHost.subviews.compactMap { $0 as? PaneContainerView }
            .map { "\($0.paneID.shortLabel)=\(Int($0.frame.width))x\(Int($0.frame.height))" }
        let card = overlayHost.isHidden ? "none" : cardReport()
        let chrome = window.map {
            "appearance=\($0.effectiveAppearance.name.rawValue)"
                + " title=\"\($0.title)\""
                + " gridLuma=\(String(format: "%.2f", model.terminalTheme.defaultBackground.relativeLuminance))"
        } ?? "chrome=none"
        let group = window?.tabGroup.map {
            "tabGroup=\($0.windows.count) barVisible=\($0.isTabBarVisible)"
                + " titles=[\($0.windows.map(\.title).joined(separator: "|"))]"
                + " merge=\(NSWindow.allowsAutomaticWindowTabbing)"
                + " id=\(self.window?.tabbingIdentifier ?? "none")"
        } ?? "tabGroup=none"
        let layoutRect = window.map {
            "contentLayout=\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height))"
                + " content=\(Int($0.contentView?.bounds.height ?? 0))"
                + " frame=\(Int($0.frame.height))"
        } ?? "no window"
        return "splitHost=\(Int(splitHost.frame.width))x\(Int(splitHost.frame.height)) "
            + "containers=[\(panes.joined(separator: ", "))] card=\(card) "
            + layoutRect + " " + chrome + " " + group
    }

    /// How much of the window a summoned surface actually covers. A panel that
    /// fills the window reads as a broken window rather than a designed card.
    private func cardReport() -> String {
        guard let host = window?.contentView else { return "unhosted" }
        let card = overlayHost.fittingSize
        let widthShare = Int((card.width / max(1, host.bounds.width) * 100).rounded())
        let heightShare = Int((card.height / max(1, host.bounds.height) * 100).rounded())
        return "\(Int(card.width.rounded()))x\(Int(card.height.rounded())) "
            + "(\(widthShare)%x\(heightShare)% of window)"
    }

    public var presentedSurface: SummonedSurface? { overlay }

    /// The presented surface's view, so a capture can composite it above the
    /// terminal content it covers.
    public var summonedSurfaceView: NSView? { overlayHost.isHidden ? nil : overlayHost }

    // MARK: Toolbar

    /// Toolbar capacity is deliberately limited to Room selection, board
    /// summon, router count, teleport, and settings (§23.1).
    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "AllwardMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }
}

extension MainWindowController: NSToolbarDelegate {
    /// The toolbar, as data.
    ///
    /// The bell and the Board button ran the same call: `focusRouter` was a
    /// copy of `showBoard`. It was not a miswire to repair - the attention
    /// router is the always-visible strip, which shows a count and has nothing
    /// to open, so "show me what needs attention" already *is* the Board. The
    /// third button went.
    ///
    /// A tooltip is not decoration here: the toolbar is icon-only, so without
    /// one an icon is the only thing telling you what a button does.
    struct ToolbarCommand {
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
        let help: String
        /// Shown when the command cannot act. A button that can go dim has to
        /// say why, or dim is just another kind of broken.
        var unavailableHelp: String?
        let action: Selector
    }

    static let toolbarCommands: [ToolbarCommand] = [
        ToolbarCommand(
            id: NSToolbarItem.Identifier("allward.room"), label: "Room",
            symbol: "square.on.square",
            help: "Switch Room. Rooms group sessions, hosts and a theme.",
            action: #selector(AllwardAppDelegate.showRoomSwitcher(_:))),
        ToolbarCommand(
            id: NSToolbarItem.Identifier("allward.board"), label: "Board",
            symbol: "rectangle.grid.1x2",
            help: "Session board. Every session and which ones need you.",
            action: #selector(AllwardAppDelegate.showBoard(_:))),
        ToolbarCommand(
            id: NSToolbarItem.Identifier("allward.teleport"), label: "Teleport",
            // Not `arrow.uturn.forward`: that is the redo arrow, and in a
            // terminal a forward arrow to a line reads as end-of-line.
            symbol: "scope",
            help: "Jump to the session that most needs attention.",
            unavailableHelp: "Nothing needs attention right now.",
            action: #selector(AllwardAppDelegate.teleport(_:))),
        ToolbarCommand(
            id: NSToolbarItem.Identifier("allward.settings"), label: "Settings",
            symbol: "gearshape", help: "Settings.",
            action: #selector(AllwardAppDelegate.showSettings(_:))),
    ]

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [Self.toolbarCommands[0].id, .flexibleSpace]
        ids.append(contentsOf: Self.toolbarCommands.dropFirst().map(\.id))
        return ids
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let command = Self.toolbarCommands.first(where: { $0.id == identifier })
        else { return nil }
        let item = SurfaceToolbarItem(
            itemIdentifier: identifier, label: command.label, symbol: command.symbol,
            help: command.help, unavailableHelp: command.unavailableHelp,
            action: command.action)
        if command.id.rawValue == "allward.teleport" {
            item.isAvailable = { [weak self] in
                (self?.model.routerState?.actionableCount ?? 0) > 0
            }
        }
        item.validate()
        return item
    }
}

extension MainWindowController: SplitHostDelegate {
    public func splitHost(_ host: SplitHostView, didResizeNodeAt path: [Int], to ratio: Double) {
        Task { await model.resizeSplit(at: path, to: ratio) }
    }
}

/// AppKit lays out top-down when a view is flipped; the terminal grid assumes
/// row zero is at the top, so every Allward container is flipped.
@MainActor
final class FlippedView: NSView {
    var onLayout: ((CGRect) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
}
