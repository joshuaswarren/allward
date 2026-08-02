import AllwardConfig
import AllwardControl
import AllwardCore
import AllwardDesign
import AllwardLocalPTY
import AllwardMultiplexer
import AllwardRenderer

import AllwardRooms
import AllwardSSH
import AllwardSurfaces
import AllwardTerminal
import AppKit
import Observation

/// The application's single owner of UI-facing state. It holds the control
/// layer, the surface store, and the live pane views, and publishes one
/// coherent view of them to the windows.
///
/// It performs no terminal work itself: every mutation goes through
/// `ControlService`, which is also what MCP and dictation call.
@MainActor
@Observable
public final class AppModel {
    public internal(set) var palette: DesignPalette
    public internal(set) var topology: TopologySnapshot
    public internal(set) var rooms: [Room] = []
    public internal(set) var configuration: Configuration
    public internal(set) var adapterHealth: AdapterHealth = .none
    public internal(set) var focusedWindow: WindowID?
    /// Which tab is focused is the control layer's answer, never a second copy
    /// kept here. Two sources drifted: the strip highlighted one tab while the
    /// split host laid out another, so switching tabs appeared to do nothing.
    public var focusedTab: TabID? {
        topology.windows.first { $0.id == focusedWindow }?.focusedTab
    }
    /// Live counters for the diagnostics surface, refreshed on real events.
    public internal(set) var diagnosticsInputs = DiagnosticsInputs()

    public let control: ControlService
    public let surfaces: SurfaceStore
    public let roomStore: RoomStore

    private let clock: any AllwardClock
    let adapter: any MultiplexerAdapter
    private let roomAdapters: RoomAdapters?
    private var paneViews: [PaneID: TerminalPaneView] = [:]
    private var paneContainers: [PaneID: PaneContainerView] = [:]
    private var snapshotTasks: [PaneID: Task<Void, Never>] = [:]
    private var theme: AllwardRenderer.TerminalTheme

    /// The grid theme the panes are painting, for the capture path.
    public var terminalTheme: AllwardRenderer.TerminalTheme { theme }
    /// One real window per tab, grouped by AppKit into a native tab bar.
    ///
    /// A custom strip cannot join Mission Control, Merge All Windows, or the
    /// system tab overview, so a tab here is an `NSWindow` and an Allward
    /// window is a tab group.
    private var tabWindows: [TabID: MainWindowController] = [:]
    @ObservationIgnored let searchState = SearchState()

    /// The window the user is acting in.
    public var keyWindowController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        return focusedTab.flatMap { tabWindows[$0] } ?? tabWindows.values.first
    }

    public init(
        configuration: Configuration,
        roomStore: RoomStore,
        surfaces: SurfaceStore,
        adapter: any MultiplexerAdapter,
        roomAdapters: RoomAdapters? = nil,
        clock: any AllwardClock = SystemClock()
    ) {
        self.configuration = configuration
        self.roomStore = roomStore
        self.surfaces = surfaces
        self.adapter = adapter
        self.roomAdapters = roomAdapters
        self.clock = clock
        self.theme = TerminalThemeBridge.rendererTheme(
            named: configuration.rooms.first?.terminalThemeName ?? "Allward Night",
            terminal: configuration.terminal)
        self.palette = DesignPalette(
            appearance: .dark, settings: SystemAccessibility.current(), contentSize: .medium)
        self.topology = TopologySnapshot(generation: .initial, windows: [], panes: [])
        self.control = ControlService(
            transports: [LocalPTYTransport(), SSHTransport()],
            adapter: adapter,
            clock: clock,
            roomStore: roomStore,
            surfaceStore: surfaces
        )
        observeSystemAppearance()
    }

    public func attach(window: MainWindowController) { tabWindows[window.tab] = window }

    /// Brings the set of real windows in line with the tabs that exist.
    ///
    /// New tabs open a window tabbed into the group; closed tabs close theirs.
    func reconcileTabWindows() {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow })
        else { return }
        let live = Set(window.tabs.map(\.id))
        for (tab, controller) in tabWindows where !live.contains(tab) {
            tabWindows[tab] = nil
            controller.window?.close()
        }
        for tab in window.tabs.map(\.id) where tabWindows[tab] == nil {
            let controller = MainWindowController(model: self, tab: tab)
            tabWindows[tab] = controller
            if let sibling = tabWindows.first(where: { $0.key != tab })?.value.window,
                let created = controller.window
            {
                sibling.addTabbedWindow(created, ordered: .above)
            }
            controller.showWindow(nil)
        }
        for controller in tabWindows.values { controller.topologyDidChange() }
        if let focused = focusedTab, let controller = tabWindows[focused] {
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Appearance

    /// Appearance and accessibility are event-driven: macOS posts a change and
    /// the palette is re-resolved once. Nothing polls the settings.
    private func observeSystemAppearance() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPalette() }
        }
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPalette() }
        }
    }

    public func refreshPalette() {
        let appearance = SystemAccessibility.appearance(
            for: keyWindowController?.window?.contentView)
        palette = DesignPalette(
            appearance: appearance,
            settings: SystemAccessibility.current(),
            contentSize: palette.contentSize,
            roomTint: activeRoom?.baseTint
        )
        theme = TerminalThemeBridge.rendererTheme(
            named: activeRoom?.terminalThemeName ?? configuration.terminal.theme,
            terminal: configuration.terminal)
        for view in paneViews.values {
            view.palette = palette
            view.theme = theme
        }
        publishThemeColorsToSessions()
        for controller in tabWindows.values { controller.paletteDidChange(palette) }
    }

    /// Keeps every engine's answer to a colour query in step with the theme.
    private func publishThemeColorsToSessions() {
        let foreground = Self.reportedColor(theme.defaultForeground)
        let background = Self.reportedColor(theme.defaultBackground)
        let cursor = Self.reportedColor(theme.cursor)
        Task { [control] in
            await control.setReportedColors(
                foreground: foreground, background: background, cursor: cursor)
        }
    }

    private static func reportedColor(_ color: TokenColor) -> DynamicColors.RGB {
        DynamicColors.RGB(
            UInt8(clamping: Int((color.red * 255).rounded())),
            UInt8(clamping: Int((color.green * 255).rounded())),
            UInt8(clamping: Int((color.blue * 255).rounded())))
    }

    public func setContentSize(_ size: ContentSizeCategory) {
        palette = DesignPalette(
            appearance: palette.appearance, settings: palette.settings, contentSize: size,
            roomTint: activeRoom?.baseTint)
        for controller in tabWindows.values { controller.paletteDidChange(palette) }
    }

    // MARK: Rooms

    public var activeRoom: Room? {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }) else {
            return rooms.first
        }
        return rooms.first { $0.id == window.room } ?? rooms.first
    }

    /// Applies one validated configuration generation everywhere it is visible.
    /// The file-reload path and the settings path both land here, so a change
    /// can never be half-applied.
    public func applyConfiguration(_ configuration: Configuration) async {
        self.configuration = configuration
        await control.setTerminalPolicy(
            TerminalPolicy(
                allowLogFile: configuration.terminal.allowLogFile,
                allowClipboardRead: configuration.terminal.allowClipboardRead))
        try? await roomStore.replaceRooms(configuration.rooms)
        rooms = await roomStore.rooms()
        await roomAdapters?.apply(configuration.rooms)
        refreshPalette()
        for container in containers.values {
            container.terminal.setFont(
                family: configuration.terminal.fontFamily, size: configuration.terminal.fontSize)
        }
        await refreshSurfaceProjection()
    }

    public func loadRooms() async {
        rooms = await roomStore.rooms()
        refreshPalette()
    }

    public func tint(for room: RoomID) -> TokenColor {
        rooms.first { $0.id == room }?.baseTint ?? DesignPalette.neutralTint(palette.appearance)
    }

    public func name(for room: RoomID) -> String {
        rooms.first { $0.id == room }?.name ?? "Room"
    }

    // MARK: Panes

    public func paneView(for pane: PaneID) -> TerminalPaneView? { paneViews[pane] }
    public func container(for pane: PaneID) -> PaneContainerView? { paneContainers[pane] }
    public var containers: [PaneID: PaneContainerView] { paneContainers }

    public var focusedPane: PaneID? {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }),
            let tab = window.tabs.first(where: { $0.id == window.focusedTab })
        else { return topology.windows.first?.tabs.first?.focusedPane }
        return tab.focusedPane
    }

    /// Creates the view pair for a pane and begins consuming its snapshots. The
    /// views outlive layout changes so a split never restarts a terminal.
    public func adoptPane(_ pane: PaneID) {
        guard paneViews[pane] == nil else { return }
        let view = TerminalPaneView(
            palette: palette, theme: theme,
            fontFamily: configuration.terminal.fontFamily,
            fontSize: configuration.terminal.fontSize)
        view.delegate = self
        paneViews[pane] = view
        paneContainers[pane] = PaneContainerView(paneID: pane, terminal: view)
        snapshotTasks[pane] = Task { [weak self] in
            guard let stream = await self?.control.snapshots(for: pane) else { return }
            for await snapshot in stream {
                guard let self else { return }
                self.paneViews[pane]?.apply(snapshot, focused: self.focusedPane == pane)
                self.refreshHeader(for: pane, snapshot: snapshot)
            }
            // The stream ends when the shell exits. Typing `exit` has to take
            // the pane with it, and the tab and window when it was the last
            // one, which is what every terminal does and what this did not.
            guard !Task.isCancelled, let self else { return }
            await self.paneSessionEnded(pane)
        }
    }

    /// The pane's process is gone, so the pane goes too.
    private func paneSessionEnded(_ pane: PaneID) async {
        topology = await control.listPanes()
        guard let entry = topology.panes.first(where: { $0.id == pane }) else { return }
        await applyingLiveGeneration { generation in
            await control.closePane(
                target: paneTarget(entry, pane), generation: generation,
                idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    public func releasePane(_ pane: PaneID) {
        snapshotTasks[pane]?.cancel()
        snapshotTasks[pane] = nil
        paneContainers[pane]?.removeFromSuperview()
        paneContainers[pane] = nil
        paneViews[pane] = nil
    }

    public func refreshTopology() async {
        let previousActiveRoomID = activeRoom?.id
        topology = await control.listPanes()
        if focusedWindow == nil || !topology.windows.contains(where: { $0.id == focusedWindow }) {
            focusedWindow = topology.windows.first?.id
        }
        if previousActiveRoomID != activeRoom?.id {
            await roomAdapters?.activate(activeRoom)
        }
        for pane in topology.panes { adoptPane(pane.id) }
        let live = Set(topology.panes.map(\.id))
        for pane in paneViews.keys where !live.contains(pane) { releasePane(pane) }
        reconcileTabWindows()
        await refreshSurfaceProjection()
    }

    // MARK: Headers

    /// The user-facing session name for a pane header, in order of how much it
    /// tells a human: the shell's own title, then the working directory, then
    /// the route it came from.
    func paneTitle(snapshot: TerminalSnapshot, entry: PaneTopology) -> String {
        if let title = snapshot.title, !title.isEmpty { return title }
        if let directory = snapshot.commandRegions.last?.workingDirectory,
            directory.isEmpty == false
        {
            let name = (directory as NSString).lastPathComponent
            return name.isEmpty ? directory : name
        }
        return entry.destination.provenanceLabel
    }

    private func refreshHeader(for pane: PaneID, snapshot: TerminalSnapshot) {
        guard let entry = topology.panes.first(where: { $0.id == pane }),
            let container = paneContainers[pane]
        else { return }
        let composition = SourceComposition(
            adapterHealth: adapterHealth,
            adapterOwnsTarget: entry.contentRoute != nil,
            connection: .ready
        )
        let presentation = PresentationComposer.compose(composition)
        let title = paneTitle(snapshot: snapshot, entry: entry)
        let model = PaneHeaderModel(
            roomName: name(for: entry.target.room),
            roomTint: tint(for: entry.target.room),
            showsRoomIdentity: rooms.count > 1,
            sessionName: title,
            host: entry.destination.host?.rawValue,
            paneLabel: pane.shortLabel,
            presentation: presentation,
            subject: PresentationSubject(componentName: "Pane", target: title),
            routeDisclosure: entry.contentRoute?.persistentLabel
        )
        let multiplePanes = (currentLayout()?.leaves.count ?? 1) > 1
        container.setHeader(
            model.mustPersist || multiplePanes ? model : nil,
            palette: palette,
            focused: focusedPane == pane)
    }

    // MARK: Layout

    public func currentLayout() -> PaneLayoutNode? {
        focusedTab.flatMap(layout(for:))
    }

    /// The pane tree a given tab's window shows.
    public func layout(for tab: TabID) -> PaneLayoutNode? {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }),
            let entry = window.tabs.first(where: { $0.id == tab }), let tree = entry.tree
        else { return nil }
        return PaneLayoutNode(tree)
    }

    // MARK: Operations

    /// Every mutating operation addresses an exact pane, so the target always
    /// carries the pane identity rather than passing it beside the target.
    func paneTarget(_ entry: PaneTopology, _ pane: PaneID) -> Target {
        Target(room: entry.target.room, session: entry.target.session, pane: pane)
    }

    /// The control layer rejects a mutation carrying a stale generation, which
    /// is correct. The UI therefore reads the live generation immediately
    /// before it acts instead of trusting its cached snapshot.
    /// Applies a mutation against the live generation, retrying once when the
    /// control layer reports a stale generation.
    ///
    /// The strict generation check exists so an external caller cannot act on a
    /// stale view, and it stays strict. The owning UI, though, is acting on
    /// whatever is current by definition, and another of its own operations can
    /// land between reading the generation and using it. One bounded retry
    /// resolves that without weakening the contract: the retry revalidates the
    /// target, so a genuine conflict still fails.
    @discardableResult
    func applyingLiveGeneration(
        _ operation: (Generation) async -> ControlMutationResult
    ) async -> ControlMutationResult {
        var result = await operation(await liveGeneration())
        if case .rejected(.staleGeneration) = result {
            result = await operation(await liveGeneration())
        }
        if case let .rejected(rejection) = result {
            lastActionMessage = "Operation refused: \(rejection)"
        }
        return result
    }

    func liveGeneration() async -> Generation {
        topology = await control.listPanes()
        return topology.generation
    }

    private func nextKey() -> IdempotencyKey { IdempotencyKey(rawValue: UUID().uuidString) }

    public func newLocalPane() async {
        guard let window = focusedWindow, let tab = focusedTab,
            let room = topology.windows.first(where: { $0.id == window })?.room
        else { return }
        let request = PaneCreationRequest(
            window: window, tab: tab, geometry: projectedPaneGeometry(),
            workingDirectory: activeRoom?.defaults.workingDirectory, environment: [:])
        await applyingLiveGeneration { generation in
            await control.createLocalPane(
                target: Target(room: room), generation: generation, request: request,
                idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    public func newSSHPane(host: HostAlias) async {
        guard let window = focusedWindow, let tab = focusedTab,
            let room = topology.windows.first(where: { $0.id == window })?.room
        else { return }
        let request = PaneCreationRequest(
            window: window, tab: tab, geometry: projectedPaneGeometry(), workingDirectory: nil, environment: [:])
        await applyingLiveGeneration { generation in
            await control.createSSHPane(
                target: Target(room: room), generation: generation, request: request,
                host: host, idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    public func splitFocusedPane(_ orientation: SplitOrientation) async {
        topology = await control.listPanes()
        guard let pane = focusedPane else {
            lastActionMessage = "Split needs a focused pane; none is focused."
            return
        }
        guard let entry = topology.panes.first(where: { $0.id == pane }) else {
            lastActionMessage = "Split target \(pane.shortLabel) is no longer present."
            return
        }
        await applyingLiveGeneration { generation in
            await control.splitPane(
                target: paneTarget(entry, pane), generation: generation,
                destination: entry.destination, orientation: orientation,
                idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    public func closeFocusedPane() async {
        topology = await control.listPanes()
        guard let pane = focusedPane,
            let entry = topology.panes.first(where: { $0.id == pane })
        else {
            lastActionMessage = "Close needs a focused pane; none is focused."
            return
        }
        await applyingLiveGeneration { generation in
            await control.closePane(
                target: paneTarget(entry, pane), generation: generation,
                idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    /// A dragged divider is a layout mutation: the model owns the tree, the
    /// control layer validates the generation, and the host re-renders.
    public func resizeSplit(at path: [Int], to ratio: Double) async {
        guard let pane = focusedPane,
            let entry = topology.panes.first(where: { $0.id == pane })
        else { return }
        let branches = path.map { $0 == 0 ? SplitBranch.first : SplitBranch.second }
        await applyingLiveGeneration { generation in
            await control.resizeDivider(
                target: paneTarget(entry, pane), generation: generation, pane: pane,
                path: SplitPath(branches), ratio: ratio, idempotencyKey: nextKey())
        }
        await refreshTopology()
    }

    public func focus(_ pane: PaneID) async {
        // Making a pane first responder calls back into here. Re-issuing focus
        // for the pane that already has it would advance the topology
        // generation on every layout pass, which both burns work and makes
        // every concurrent mutation fail its generation check.
        guard focusedPane != pane else { return }
        guard let entry = topology.panes.first(where: { $0.id == pane }) else { return }
        await applyingLiveGeneration { generation in
            await control.focusPane(
                target: paneTarget(entry, pane), generation: generation,
                idempotencyKey: nextKey())
        }
        await refreshTopology()
    }
}

// MARK: - Terminal input

extension AppModel: TerminalPaneDelegate {
    public func pane(_ pane: TerminalPaneView, send bytes: [UInt8]) {
        guard let id = paneID(for: pane) else { return }
        Task { await control.session(for: id)?.write(bytes) }
    }

    public func pane(_ pane: TerminalPaneView, resizeTo geometry: TerminalGeometry) {
        guard let id = paneID(for: pane) else { return }
        Task {
            await control.session(for: id)?
                .resize(columns: geometry.columns, rows: geometry.rows)
        }
    }

    public func pane(_ pane: TerminalPaneView, didChangeSelection selection: Selection?) {
        guard let id = paneID(for: pane) else { return }
        Task { await control.session(for: id)?.setSelection(selection) }
    }

    public func paneDidBecomeFirstResponder(_ pane: TerminalPaneView) {
        guard let id = paneID(for: pane) else { return }
        Task { await focus(id) }
    }

    public func paneRequestsScroll(_ pane: TerminalPaneView, byRows rows: Int) {
        guard let id = paneID(for: pane) else { return }
        Task { await control.session(for: id)?.scroll(byRows: rows) }
    }

    private func paneID(for view: TerminalPaneView) -> PaneID? {
        paneViews.first { $0.value === view }?.key
    }
}

extension PaneLayoutNode {
    /// Projects the control layer's split tree into the layout the host renders.
    init(_ tree: SplitTree) {
        switch tree {
        case .leaf(let pane):
            self = .leaf(pane)
        case .split(let orientation, let ratio, let children):
            self = .split(
                axis: orientation == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                first: PaneLayoutNode(children.first),
                second: PaneLayoutNode(children.second))
        }
    }
}
