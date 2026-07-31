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
    public internal(set) var focusedTab: TabID?
    /// Live counters for the diagnostics surface, refreshed on real events.
    public internal(set) var diagnosticsInputs = DiagnosticsInputs()

    public let control: ControlService
    public let surfaces: SurfaceStore
    public let roomStore: RoomStore

    private let clock: any AllwardClock
    let adapter: any MultiplexerAdapter
    private var paneViews: [PaneID: TerminalPaneView] = [:]
    private var paneContainers: [PaneID: PaneContainerView] = [:]
    private var snapshotTasks: [PaneID: Task<Void, Never>] = [:]
    private var theme: AllwardRenderer.TerminalTheme

    /// The grid theme the panes are painting, for the capture path.
    public var terminalTheme: AllwardRenderer.TerminalTheme { theme }
    private weak var mainWindow: MainWindowController?

    public init(
        configuration: Configuration,
        roomStore: RoomStore,
        surfaces: SurfaceStore,
        adapter: any MultiplexerAdapter,
        clock: any AllwardClock = SystemClock()
    ) {
        self.configuration = configuration
        self.roomStore = roomStore
        self.surfaces = surfaces
        self.adapter = adapter
        self.clock = clock
        self.theme = TerminalThemeBridge.rendererTheme(
            named: configuration.rooms.first?.terminalThemeName ?? "Allward Night")
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

    public func attach(window: MainWindowController) { mainWindow = window }

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
        let appearance = SystemAccessibility.appearance(for: mainWindow?.window?.contentView)
        palette = DesignPalette(
            appearance: appearance,
            settings: SystemAccessibility.current(),
            contentSize: palette.contentSize,
            roomTint: activeRoom?.baseTint
        )
        theme = TerminalThemeBridge.rendererTheme(
            named: activeRoom?.terminalThemeName ?? configuration.terminal.theme)
        for view in paneViews.values {
            view.palette = palette
            view.theme = theme
        }
        mainWindow?.paletteDidChange(palette)
    }

    public func setContentSize(_ size: ContentSizeCategory) {
        palette = DesignPalette(
            appearance: palette.appearance, settings: palette.settings, contentSize: size,
            roomTint: activeRoom?.baseTint)
        mainWindow?.paletteDidChange(palette)
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
        try? await roomStore.replaceRooms(configuration.rooms)
        rooms = await roomStore.rooms()
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
        }
    }

    public func releasePane(_ pane: PaneID) {
        snapshotTasks[pane]?.cancel()
        snapshotTasks[pane] = nil
        paneContainers[pane]?.removeFromSuperview()
        paneContainers[pane] = nil
        paneViews[pane] = nil
    }

    public func refreshTopology() async {
        topology = await control.listPanes()
        if focusedWindow == nil || !topology.windows.contains(where: { $0.id == focusedWindow }) {
            focusedWindow = topology.windows.first?.id
        }
        focusedTab = topology.windows.first { $0.id == focusedWindow }?.focusedTab
        for pane in topology.panes { adoptPane(pane.id) }
        let live = Set(topology.panes.map(\.id))
        for pane in paneViews.keys where !live.contains(pane) { releasePane(pane) }
        mainWindow?.topologyDidChange()
        await refreshSurfaceProjection()
    }

    // MARK: Headers

    /// The user-facing session name for a pane header, in order of how much it
    /// tells a human: the shell's own title, then the working directory, then
    /// the route it came from.
    private func paneTitle(snapshot: TerminalSnapshot, entry: PaneTopology) -> String {
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
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }),
            let tab = window.tabs.first(where: { $0.id == window.focusedTab }),
            let tree = tab.tree
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
            window: window, tab: tab, geometry: .standard,
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
            window: window, tab: tab, geometry: .standard, workingDirectory: nil, environment: [:])
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
