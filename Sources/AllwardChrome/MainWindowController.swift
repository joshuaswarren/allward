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
    private let tabHost: NSHostingView<AnyView>
    private let routerHost: NSHostingView<AnyView>
    private let overlayHost: NSHostingView<AnyView>
    private let roomSeam = NSView()
    private var overlay: SummonedSurface?

    /// Which summoned surface is on screen. Exactly one at a time, so focus
    /// transfer and restoration stay unambiguous.
    public enum SummonedSurface: Equatable {
        case board
        case digest
        case commandPalette
        case settings
        case diagnostics
        case onboarding
        case roomSwitcher
        case hostPicker
    }

    public init(model: AppModel) {
        self.model = model
        self.splitHost = SplitHostView(palette: model.palette)
        self.tabHost = NSHostingView(rootView: AnyView(EmptyView()))
        self.routerHost = NSHostingView(rootView: AnyView(EmptyView()))
        self.overlayHost = NSHostingView(rootView: AnyView(EmptyView()))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Allward"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.tabbingMode = .preferred
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("AllwardMainWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
        model.attach(window: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MainWindowController is code-only") }

    private func buildContent() {
        guard let window else { return }
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = model.terminalTheme.defaultBackground.cgColor

        splitHost.delegate = self
        roomSeam.wantsLayer = true
        overlayHost.isHidden = true
        tabHost.isHidden = true

        root.addSubview(roomSeam)
        root.addSubview(tabHost)
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
        let seamWidth = StrokeToken.roomSeam.width(model.palette.settings)
        roomSeam.frame = CGRect(x: 0, y: 0, width: seamWidth, height: bounds.height)
        let contentX = seamWidth
        let contentWidth = bounds.width - seamWidth
        let tabHeight = tabHost.isHidden ? 0 : tabHost.fittingSize.height
        let routerHeight = routerHost.isHidden ? 0 : routerHost.fittingSize.height
        tabHost.frame = CGRect(x: contentX, y: 0, width: contentWidth, height: tabHeight)
        splitHost.frame = CGRect(
            x: contentX, y: tabHeight, width: contentWidth,
            height: max(0, bounds.height - tabHeight - routerHeight))
        routerHost.frame = CGRect(
            x: contentX, y: splitHost.frame.maxY, width: contentWidth, height: routerHeight)
        overlayHost.frame = bounds
    }

    // MARK: Palette and topology

    public func paletteDidChange(_ palette: DesignPalette) {
        splitHost.palette = palette
        applyPalette()
    }

    private func applyPalette() {
        window?.contentView?.layer?.backgroundColor =
            model.terminalTheme.defaultBackground.cgColor
        roomSeam.layer?.backgroundColor = model.palette[.seam].cgColor
        window?.appearance = NSAppearance(
            named: model.palette.appearance == .dark ? .darkAqua : .aqua)
        window?.contentView?.needsLayout = true
    }

    public func topologyDidChange() {
        splitHost.setContainers(model.containers)
        splitHost.setLayout(model.currentLayout())
        refreshTabStrip()
        window?.title = model.activeRoom.map { "Allward — \($0.name)" } ?? "Allward"
        if let pane = model.focusedPane, let view = model.paneView(for: pane),
            window?.firstResponder !== view
        {
            window?.makeFirstResponder(view)
        }
        window?.contentView?.needsLayout = true
    }


    /// The strip only exists once a second tab does, so a single session keeps
    /// the whole window for the grid.
    private func refreshTabStrip() {
        let items = model.tabStripItems()
        guard items.count > 1 else {
            tabHost.isHidden = true
            return
        }
        tabHost.isHidden = false
        tabHost.rootView = AnyView(
            TabStripView(
                tabs: items,
                selected: model.focusedTab,
                roomTint: model.activeRoom?.baseTint
                    ?? DesignPalette.neutralTint(model.palette.appearance),
                onSelect: { [weak model] tab in Task { await model?.focusTab(tab) } },
                onClose: { [weak model] tab in Task { await model?.closeTab(tab) } },
                onNew: { [weak model] in Task { await model?.newTab() } }
            )
            .allwardPalette(model.palette))
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
        overlayHost.rootView = AnyView(
            content
                .allwardPalette(model.palette)
                .background(model.palette[.surfaceScrim].swiftUIColor)
        )
        window?.makeFirstResponder(overlayHost)
    }

    public func dismissSummonedSurface() {
        guard overlay != nil else { return }
        overlay = nil
        overlayHost.isHidden = true
        overlayHost.rootView = AnyView(EmptyView())
        if let pane = model.focusedPane, let view = model.paneView(for: pane) {
            window?.makeFirstResponder(view)
        } else {
            window?.makeFirstResponder(splitHost)
        }
    }

    /// Frames of the laid-out pane containers, for capture-mode diagnostics.
    public func layoutReport() -> String {
        let panes = splitHost.subviews.compactMap { $0 as? PaneContainerView }
            .map { "\($0.paneID.shortLabel)=\(Int($0.frame.width))x\(Int($0.frame.height))" }
        return "splitHost=\(Int(splitHost.frame.width))x\(Int(splitHost.frame.height)) "
            + "containers=[\(panes.joined(separator: ", "))]"
    }

    public var presentedSurface: SummonedSurface? { overlay }

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
    private static let roomItem = NSToolbarItem.Identifier("allward.room")
    private static let boardItem = NSToolbarItem.Identifier("allward.board")
    private static let routerItem = NSToolbarItem.Identifier("allward.router")
    private static let teleportItem = NSToolbarItem.Identifier("allward.teleport")
    private static let settingsItem = NSToolbarItem.Identifier("allward.settings")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.roomItem, .flexibleSpace, Self.routerItem, Self.boardItem, Self.teleportItem,
            Self.settingsItem,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.roomItem:
            item.label = "Room"
            item.image = NSImage(
                systemSymbolName: "square.on.square", accessibilityDescription: "Switch Room")
            item.action = #selector(AllwardAppDelegate.showRoomSwitcher(_:))
        case Self.boardItem:
            item.label = "Board"
            item.image = NSImage(
                systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Session board")
            item.action = #selector(AllwardAppDelegate.showBoard(_:))
        case Self.routerItem:
            item.label = "Attention"
            item.image = NSImage(
                systemSymbolName: "bell.badge", accessibilityDescription: "Attention router")
            item.action = #selector(AllwardAppDelegate.focusRouter(_:))
        case Self.teleportItem:
            item.label = "Teleport"
            item.image = NSImage(
                systemSymbolName: "arrow.uturn.forward",
                accessibilityDescription: "Teleport to routed destination")
            item.action = #selector(AllwardAppDelegate.teleport(_:))
        case Self.settingsItem:
            item.label = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.action = #selector(AllwardAppDelegate.showSettings(_:))
        default:
            return nil
        }
        item.isBordered = true
        item.target = nil
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
