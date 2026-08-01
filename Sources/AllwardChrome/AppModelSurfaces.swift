import AllwardConfig
import AllwardControl
import AllwardCore
import AllwardDesign
import AllwardMultiplexer
import AllwardRenderer
import AllwardRooms
import AllwardSurfaces
import AllwardTerminal
import AppKit
import Foundation
import Observation

@MainActor
@Observable
private final class AppSurfaceState {
    var board: BoardViewState?
    var router: RouterViewState?
    var digest: DigestViewState?
    var lastActionMessage: String?
    var messageClearTask: Task<Void, Never>?
    var snapshot: SurfaceSnapshot?
    var projectedGeneration: Generation?
    var selectedSettingsTab: SettingsTab = .general
    var adapterSessionsByRecord: [RecordID: AdapterSession] = [:]
    @ObservationIgnored weak var observedWindow: MainWindowController?
    /// The geometry the most recent shell was actually started at.
    @ObservationIgnored var lastSpawnGeometry: TerminalGeometry?
    @ObservationIgnored var adapterTask: Task<Void, Never>?
}

@MainActor
private var appSurfaceStates: [ObjectIdentifier: AppSurfaceState] = [:]

@MainActor
private func surfaceState(for model: AppModel) -> AppSurfaceState {
    let key = ObjectIdentifier(model)
    if let state = appSurfaceStates[key] { return state }
    let state = AppSurfaceState()
    appSurfaceStates[key] = state
    return state
}

@MainActor
extension AppModel {
    public var boardState: BoardViewState? {
        get { surfaceState(for: self).board }
        set { surfaceState(for: self).board = newValue }
    }

    public var routerState: RouterViewState? {
        get { surfaceState(for: self).router }
        set { surfaceState(for: self).router = newValue }
    }

    public var digestState: DigestViewState? {
        get { surfaceState(for: self).digest }
        set { surfaceState(for: self).digest = newValue }
    }

    /// The settings section to open. Stored on the model so anything - a deep
    /// link, the palette, a test - can decide which one you land on.
    public var selectedSettingsTab: SettingsTab {
        get { surfaceState(for: self).selectedSettingsTab }
        set { surfaceState(for: self).selectedSettingsTab = newValue }
    }

    /// What the last action had to say for itself.
    ///
    /// Until now nothing displayed this. Every refusal in the application -
    /// "Close Work's windows before deleting it", "The attention router has no
    /// actionable destination" - was written here and read only by the capture
    /// harness, so from the outside those actions did nothing at all. Setting
    /// it now shows it, and clears it again so it stays a message rather than
    /// becoming furniture.
    public var lastActionMessage: String? {
        get { surfaceState(for: self).lastActionMessage }
        set {
            let state = surfaceState(for: self)
            state.lastActionMessage = newValue
            state.messageClearTask?.cancel()
            guard newValue != nil else { return }
            state.messageClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                surfaceState(for: self).lastActionMessage = nil
                await projectSurfaceSnapshot(for: self, force: true)
            }
            Task { [weak self] in
                guard let self else { return }
                await projectSurfaceSnapshot(for: self, force: true)
            }
        }
    }

    public func openInitialSession(tab: TabID? = nil) async {
        guard topology.windows.isEmpty else {
            await refreshTopology()
            return
        }
        guard let room = configuration.rooms.first else {
            lastActionMessage = "No configured Room is available for the initial session."
            return
        }
        await createWindowSession(room: room, requireLocalPane: false, tab: tab)
    }

    public func openNewWindow() async {
        guard let room = activeRoom ?? configuration.rooms.first else {
            lastActionMessage = "No configured Room is available for a new window."
            return
        }
        await createWindowSession(room: room, requireLocalPane: true)
    }

    public func moveFocus(_ direction: FocusDirection) async {
        guard let pane = focusedPane,
              let entry = topology.panes.first(where: { $0.id == pane }) else {
            lastActionMessage = "There is no focused pane to move from."
            return
        }
        let result = await control.movePaneFocus(
            target: paneTarget(entry, pane),
            generation: await liveGeneration(),
            direction: direction,
            idempotencyKey: surfaceMutationKey()
        )
        recordSurfaceMutationResult(result, action: "Move pane focus")
        await refreshTopology()
    }

    public func teleportToRoutedDestination() async {
        let router = await control.routerSnapshot()
        guard let item = router.items.filter(\.isActionable).min(by: routerItemHasLowerPriority) else {
            lastActionMessage = "The attention router has no actionable destination."
            return
        }
        await surfaceTeleport(to: item.target, adapterSession: adapterSession(for: item.id))
    }

    /// The non-blank rows of the focused pane, so a redraw complaint can be
    /// checked against what the grid really holds.
    public func rowDump() -> String {
        guard let pane = focusedPane, let snapshot = paneView(for: pane)?.snapshot
        else { return "no pane" }
        var lines: [String] = ["scrollback=\(snapshot.scrollbackCount) offset=\(snapshot.scrollOffset)"]
        for row in 0 ..< snapshot.geometry.rows {
            let text = snapshot.plainText(row: row)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("r\(row): \(text.prefix(60))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The grid each pane's terminal actually holds, and where its content
    /// starts, so a claim about prompt position is a measurement.
    public func gridReport() -> String {
        let projected = projectedPaneGeometry()
        let host = surfaceState(for: self).observedWindow?.paneHostSize
        let hostText = host.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let spawned = surfaceState(for: self).lastSpawnGeometry
        let spawnText = spawned.map { "\($0.columns)x\($0.rows)" } ?? "nil"
        return "projected=\(projected.columns)x\(projected.rows) spawned=\(spawnText) "
            + "host=\(hostText) "
            + containers.map { id, container in
            guard let snapshot = container.terminal.snapshot else {
                return "\(id.shortLabel)=none"
            }
            let firstUsedRow = snapshot.rows.firstIndex { !$0.allSatisfy(\.isBlank) }
            let view = paneView(for: id)
            let viewState = view.map {
                "view=\(Int($0.bounds.width))x\(Int($0.bounds.height))"
                    + " inTree=\($0.window != nil) still=\($0.snapshot != nil)"
            } ?? "view=none"
            return "\(id.shortLabel)=\(snapshot.geometry.columns)x\(snapshot.geometry.rows)"
                + " firstRow=\(firstUsedRow.map(String.init) ?? "none")"
                + " \(viewState)"
        }
        .sorted()
        .joined(separator: " ")
    }

    /// Resolve the spawn geometry and remember it, so diagnostics can show the
    /// size a shell actually started at rather than the size it ended up.
    func recordedSpawnGeometry(splitting orientation: SplitOrientation? = nil)
        -> TerminalGeometry
    {
        let geometry = projectedPaneGeometry(splitting: orientation)
        surfaceState(for: self).lastSpawnGeometry = geometry
        return geometry
    }

    /// The grid a newly created pane will occupy.
    ///
    /// A shell that starts at a placeholder size prints its first prompt into
    /// that smaller grid, and a later resize cannot move what was already
    /// drawn: the prompt stays stranded wherever the small grid left it. So the
    /// size is resolved before the shell starts, from the pane the new one is
    /// born beside, or from the window itself when there is no pane yet.
    public func projectedPaneGeometry(splitting orientation: SplitOrientation? = nil)
        -> TerminalGeometry
    {
        guard var size = projectedPaneArea() else { return .standard }
        switch orientation {
        case .horizontal: size.width = (size.width - 1) / 2
        case .vertical: size.height = (size.height - 1) / 2
        case nil: break
        }
        return TerminalGeometry.fitting(
            CGSize(width: max(1, size.width), height: max(1, size.height)),
            metrics: paneMetrics(), scale: referenceScale)
    }

    /// Cell metrics are rasterised in device pixels, so the grid arithmetic
    /// only holds when both use the same scale. A window that has not reached a
    /// screen yet still reports 1, which would start a shell at half the rows.
    private var referenceScale: CGFloat {
        if let pane = focusedPane ?? containers.keys.first,
            let view = paneView(for: pane),
            let scale = view.window?.screen?.backingScaleFactor
        {
            return scale
        }
        return surfaceState(for: self).observedWindow?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func projectedPaneArea() -> CGSize? {
        if let pane = focusedPane ?? containers.keys.first, let view = paneView(for: pane) {
            return view.bounds.size.reduced(by: TerminalPaneView.gridInsetSize)
        }
        guard let host = surfaceState(for: self).observedWindow?.paneHostSize else { return nil }
        return host.reduced(by: TerminalPaneView.gridInsetSize)
    }

    private func paneMetrics() -> CellMetrics {
        if let pane = focusedPane ?? containers.keys.first, let view = paneView(for: pane) {
            return view.metrics
        }
        return FontMetrics.metrics(
            family: configuration.terminal.fontFamily,
            size: configuration.terminal.fontSize,
            scale: referenceScale)
    }

    public func startSurfaceObservation(window: MainWindowController) async {
        let state = surfaceState(for: self)
        state.observedWindow = window
        await projectSurfaceSnapshot(for: self, window: window, force: true)
        startAdapterSurfaceObservation(for: self, state: state)
    }

    public func refreshSurfaceProjection() async {
        await projectSurfaceSnapshot(for: self)
    }

    public func applySettingsUpdate(_ update: SettingsUpdate) async {
        let state = surfaceState(for: self)
        if case let .selectTab(tab) = update {
            state.selectedSettingsTab = tab
            await projectSurfaceSnapshot(for: self, force: true)
            return
        }

        var updated = configuration
        guard apply(update, to: &updated) else { return }
        do {
            let written = try await updated.writeOffMainThread(to: AllwardPaths.configurationFile())
            lastActionMessage = nil
            await applyConfiguration(written)
        } catch {
            lastActionMessage = "Settings were not saved: \(error.localizedDescription)"
        }
    }

    fileprivate func recordSurfaceMutationResult(_ result: ControlMutationResult, action: String) {
        switch result {
        case .applied:
            lastActionMessage = nil
        case let .rejected(reason):
            lastActionMessage = "\(action) was rejected: \(String(describing: reason))"
        }
    }

    fileprivate func surfaceTeleport(to target: Target, adapterSession: AdapterSession? = nil) async {
        let destination: TeleportDestination
        if let pane = destinationPane(for: target) {
            destination = TeleportDestination(pane: pane)
        } else if let adapterSession {
            destination = TeleportDestination(adapterSession: adapterSession)
        } else {
            lastActionMessage = "The routed item has no destination that Allward can open."
            return
        }
        let result = await control.teleport(
            target: Target(room: target.room),
            generation: await liveGeneration(),
            to: destination,
            idempotencyKey: surfaceMutationKey()
        )
        recordSurfaceMutationResult(result, action: "Teleport")
        await refreshTopology()
    }

    fileprivate func adapterSession(for recordID: RecordID) -> AdapterSession? {
        surfaceState(for: self).adapterSessionsByRecord[recordID]
    }

    private func createWindowSession(
        room: Room,
        requireLocalPane: Bool,
        tab preferredTab: TabID? = nil
    ) async {
        let windowID = WindowID()
        let tabID = preferredTab ?? TabID()
        let tabResult = await control.createTab(
            target: Target(room: room.id),
            generation: await liveGeneration(),
            window: windowID,
            tab: tabID,
            idempotencyKey: surfaceMutationKey()
        )
        guard case let .applied(tabReceipt) = tabResult else {
            recordSurfaceMutationResult(tabResult, action: "Create window")
            return
        }

        let request = PaneCreationRequest(
            window: windowID,
            tab: tabID,
            geometry: recordedSpawnGeometry(),
            workingDirectory: room.defaults.workingDirectory,
            environment: [:]
        )
        let paneResult: ControlMutationResult
        if requireLocalPane || roomAllowsLocalShell(room) {
            paneResult = await control.createLocalPane(
                target: Target(room: room.id),
                generation: tabReceipt.generationAfter,
                request: request,
                idempotencyKey: surfaceMutationKey()
            )
        } else if let host = configuredInitialHost(for: room) {
            paneResult = await control.createSSHPane(
                target: Target(room: room.id),
                generation: tabReceipt.generationAfter,
                request: request,
                host: host,
                idempotencyKey: surfaceMutationKey()
            )
        } else {
            lastActionMessage = "Local shells are disabled and no SSH host is configured."
            return
        }

        recordSurfaceMutationResult(paneResult, action: "Create initial pane")
        guard case .applied = paneResult else { return }
        focusedWindow = windowID
        await refreshTopology()
    }

    private func roomAllowsLocalShell(_ room: Room) -> Bool {
        if case .local = room.defaults.destination { return true }
        return false
    }

    private func configuredInitialHost(for room: Room) -> HostAlias? {
        if case let .host(alias) = room.defaults.destination,
           configuration.hosts.contains(where: { $0.alias == alias }) {
            return alias
        }
        return configuration.hosts.first?.alias
    }

    private func destinationPane(for target: Target) -> PaneID? {
        if let pane = target.pane { return pane }
        guard let session = target.session else { return nil }
        return topology.panes.first(where: { $0.session == session })?.id
    }

    private func apply(_ update: SettingsUpdate, to configuration: inout Configuration) -> Bool {
        switch update {
        case .selectTab:
            return false
        case let .updateGeneral(itemID, value):
            return applyGeneralSetting(itemID: itemID, value: value, to: &configuration)
        case let .selectRoomTint(roomID, tintID):
            guard let id = UUID(uuidString: roomID),
                  let tint = SurfaceProjection.tint(forID: tintID),
                  let index = configuration.rooms.firstIndex(where: { $0.id.rawValue == id }) else {
                lastActionMessage = "The selected Room tint is not valid."
                return false
            }
            configuration.rooms[index].baseTint = tint
            return true
        case .addRoom:
            // Personal and Work are a starting point, not the shape of
            // everyone's work.
            RoomMutation.add(
                to: &configuration.rooms,
                tint: DesignPalette.neutralTint(palette.appearance),
                themeName: configuration.terminal.theme)
            return true
        case let .renameRoom(roomID, name):
            guard let id = Self.parseRoomID(roomID) else { return false }
            return RoomMutation.rename(id, to: name, in: &configuration.rooms)
        case let .deleteRoom(roomID):
            guard let id = Self.parseRoomID(roomID),
                let room = configuration.rooms.first(where: { $0.id == id })
            else { return false }
            guard !topology.windows.contains(where: { $0.room == room.id }) else {
                lastActionMessage = "Close \(room.name)'s windows before deleting it."
                return false
            }
            guard RoomMutation.delete(id, from: &configuration.rooms) else {
                lastActionMessage = "The last Room cannot be deleted."
                return false
            }
            return true
        case let .selectRoomTheme(roomID, themeID):
            guard let id = UUID(uuidString: roomID),
                  let index = configuration.rooms.firstIndex(where: { $0.id.rawValue == id }),
                  ThemeCatalog.theme(named: themeID) != nil else {
                lastActionMessage = "The selected Room theme is not available."
                return false
            }
            configuration.rooms[index].terminalThemeName = themeID
            return true
        case let .setRoomEarcon(roomID, earcon, enabled):
            guard let id = UUID(uuidString: roomID),
                  let index = configuration.rooms.firstIndex(where: { $0.id.rawValue == id }) else {
                lastActionMessage = "The selected Room is no longer configured."
                return false
            }
            if enabled {
                configuration.rooms[index].notificationRules.enabledEarcons.insert(earcon)
            } else {
                configuration.rooms[index].notificationRules.enabledEarcons.remove(earcon)
            }
            return true
        case let .selectTheme(themeID):
            guard ThemeCatalog.theme(named: themeID) != nil else {
                lastActionMessage = "The selected terminal theme is not available."
                return false
            }
            // A Room owns its theme, so writing only the global default meant
            // this control could never change anything you were looking at.
            // It sets the Room you are in, and the default for the next one.
            configuration.terminal.theme = themeID
            if let room = activeRoom?.id,
                let index = configuration.rooms.firstIndex(where: { $0.id == room })
            {
                configuration.rooms[index].terminalThemeName = themeID
            }
            return true
        case let .setKeyShortcut(keyID, shortcut):
            guard keyID == "speech.dictation-key" else {
                lastActionMessage = "That shortcut is fixed by the application menu."
                return false
            }
            configuration.dictationKey = shortcut
            return true
        case let .setIntegration(integrationID, enabled):
            guard Self.applyIntegration(integrationID, enabled: enabled, to: &configuration)
            else {
                lastActionMessage = "That integration is controlled by its adapter."
                return false
            }
            return true
        }
    }

    private func applyGeneralSetting(
        itemID: String,
        value: GeneralSettingValue,
        to configuration: inout Configuration
    ) -> Bool {
        guard AppModel.applySetting(itemID: itemID, value: value, to: &configuration)
        else { return invalidSetting(itemID) }
        return true
    }

    /// Maps a settings control to the configuration field it writes.
    ///
    /// Every control the settings surface renders as writable must land here.
    /// `SettingsBehaviourTests` checks the two against each other, because a
    /// control with no case is one that silently does nothing.
    static func applySetting(
        itemID: String,
        value: GeneralSettingValue,
        to configuration: inout Configuration
    ) -> Bool {
        switch (itemID, value) {
        case ("terminal.font-family", let .text(value)):
            configuration.terminal.fontFamily = value
        case ("terminal.font-size", let .number(value, _, _)):
            configuration.terminal.fontSize = value
        case ("terminal.cursor-shape", let .choice(selectedID, _)):
            guard let shape = CursorShape(rawValue: selectedID) else { return false }
            configuration.terminal.cursorShape = shape
        case ("terminal.cursor-blink", let .toggle(value)):
            configuration.terminal.cursorBlink = value
        case ("terminal.scrollback-capacity", let .number(value, _, _)):
            configuration.terminal.scrollbackCapacity = Int(value)
        case ("board.presentation", let .choice(selectedID, _)):
            guard let style = BoardPresentation(rawValue: selectedID) else { return false }
            configuration.boardPresentation = style
        case ("earcons.enabled", let .toggle(value)):
            configuration.earconsEnabled = value
        default:
            return false
        }
        return true
    }

    /// The integrations that are actually a setting rather than a readout.
    static func applyIntegration(
        _ id: String, enabled: Bool, to configuration: inout Configuration
    ) -> Bool {
        guard id == "mcp" else { return false }
        configuration.mcpEnabled = enabled
        return true
    }

    private static func parseRoomID(_ raw: String) -> RoomID? {
        UUID(uuidString: raw).map(RoomID.init(rawValue:))
    }

    private func invalidSetting(_ itemID: String) -> Bool {
        lastActionMessage = "The value for setting \(itemID) is not valid."
        return false
    }
}

@MainActor
private func projectSurfaceSnapshot(
    for model: AppModel,
    window: MainWindowController? = nil,
    force: Bool = false
) async {
    let state = surfaceState(for: model)
    let snapshot = await model.surfaces.snapshot()
    if !force, state.projectedGeneration == snapshot.generation { return }

    state.snapshot = snapshot
    state.projectedGeneration = snapshot.generation
    let now = Date()
    model.boardState = SurfaceProjection.board(
        snapshot.board,
        rooms: model.rooms,
        now: now,
        palette: model.palette
    )
    model.routerState = SurfaceProjection.router(
        snapshot.router, rooms: model.rooms, now: now, activeRoom: model.activeRoom)
    model.digestState = SurfaceProjection.digest(snapshot.digest, rooms: model.rooms, now: now)

    let targetWindow = window ?? state.observedWindow
    // DESIGN-LANGUAGE §23.5 allows the strip to be absent with nothing
    // actionable. A permanent "no actionable items" band is chrome that earns
    // nothing; the Board command stays in the toolbar and the menu.
    let message = state.lastActionMessage
    if let routerState = model.routerState,
        RouterStripView.isVisible(
            actionableCount: routerState.actionableCount,
            hasItems: !routerState.items.isEmpty, message: message)
    {
        targetWindow?.setRouterStrip(
            RouterStripView(
                state: routerState,
                message: message,
                onOpenBoard: { [weak targetWindow] in targetWindow?.presentBoard() },
                onOpenDestination: { [weak model] key in
                    guard let model else { return }
                    Task { await openRoutedDestination(key: key, model: model) }
                }
            )
        )
    } else {
        targetWindow?.setRouterStrip(Optional<RouterStripView>.none)
    }
}

@MainActor
func openSurfaceRecord(_ recordID: RecordID, model: AppModel) async {
    guard let snapshot = surfaceState(for: model).snapshot else {
        model.lastActionMessage = "Surface data has not loaded yet."
        return
    }
    let target = snapshot.records.first(where: { $0.id == recordID })?.target
        ?? snapshot.board.groups.flatMap(\.rows).first(where: { $0.id == recordID })?.target
    guard let target else {
        model.lastActionMessage = "The selected surface item is no longer available."
        return
    }
    await model.surfaceTeleport(to: target, adapterSession: model.adapterSession(for: recordID))
}

@MainActor
func openDigestSource(_ recordID: RecordID, model: AppModel) async {
    guard let fact = surfaceState(for: model).snapshot?.digest.facts.first(where: {
        $0.sourceLink.recordID == recordID
    }) else {
        model.lastActionMessage = "The selected digest source is no longer available."
        return
    }
    await model.surfaceTeleport(
        to: fact.sourceLink.target,
        adapterSession: model.adapterSession(for: fact.sourceLink.recordID)
    )
}

@MainActor
func openRoutedDestination(key: String, model: AppModel) async {
    guard let item = surfaceState(for: model).snapshot?.router.items.first(where: {
        $0.destinationKey == key && $0.isActionable
    }) else {
        model.lastActionMessage = "Destination \(key) is no longer actionable."
        return
    }
    await model.surfaceTeleport(to: item.target, adapterSession: model.adapterSession(for: item.id))
}

@MainActor
func acknowledgeSurfaceRecord(_ recordID: RecordID, model: AppModel) async {
    guard let token = surfaceState(for: model).snapshot?.router.items
        .first(where: { $0.id == recordID })?.acknowledgmentToken else {
        model.lastActionMessage = "The selected item has no current acknowledgment token."
        return
    }
    guard await model.surfaces.acknowledgeLocally(token) else {
        model.lastActionMessage = "The acknowledgment expired before it could be applied."
        await projectSurfaceSnapshot(for: model, force: true)
        return
    }
    model.lastActionMessage = nil
    await projectSurfaceSnapshot(for: model, force: true)
}

@MainActor
func acknowledgeDigest(model: AppModel) async {
    guard let token = surfaceState(for: model).snapshot?.digest.acknowledgmentToken else {
        model.lastActionMessage = "The digest has no current acknowledgment token."
        return
    }
    _ = await model.surfaces.acknowledgeDigest(token)
    model.lastActionMessage = nil
    await projectSurfaceSnapshot(for: model, force: true)
}

@MainActor
func switchRoom(_ roomID: RoomID, model: AppModel) async {
    guard let window = model.focusedWindow,
          let currentRoom = model.topology.windows.first(where: { $0.id == window })?.room else {
        model.lastActionMessage = "There is no active window to move to another Room."
        return
    }
    let result = await model.control.setRoom(
        window: window,
        room: roomID,
        target: Target(room: currentRoom),
        generation: await model.liveGeneration(),
        idempotencyKey: surfaceMutationKey()
    )
    model.recordSurfaceMutationResult(result, action: "Switch Room")
    await model.refreshTopology()
    model.refreshPalette()
}

@MainActor
private func startAdapterSurfaceObservation(for model: AppModel, state: AppSurfaceState) {
    state.adapterTask?.cancel()
    state.adapterTask = Task { [weak model] in
        guard let model else { return }
        await model.adapter.start()
        model.adapterHealth = await model.adapter.health
        do {
            let sessions = try await model.adapter.listSessions(bound: .controlRequest)
            await ingestAdapterSessions(sessions, model: model, state: state)
        } catch {
            model.lastActionMessage = "Adapter inventory failed: \(error.localizedDescription)"
            await projectSurfaceSnapshot(for: model, force: true)
        }

        for await event in model.adapter.events {
            guard !Task.isCancelled else { return }
            switch event {
            case let .health(health):
                model.adapterHealth = health
                await projectSurfaceSnapshot(for: model, force: true)
            case let .sessions(sessions):
                await ingestAdapterSessions(sessions, model: model, state: state)
            case .focusChanged:
                await projectSurfaceSnapshot(for: model, force: true)
            case let .failed(error):
                model.adapterHealth = .degraded
                model.lastActionMessage = "Adapter observation failed: \(error.localizedDescription)"
                await projectSurfaceSnapshot(for: model, force: true)
            }
        }
    }
}

@MainActor
private func ingestAdapterSessions(
    _ sessions: [AdapterSession],
    model: AppModel,
    state: AppSurfaceState
) async {
    var publications: [AdapterSessionPublication] = []
    publications.reserveCapacity(sessions.count)
    for session in sessions {
        let workspace = AdapterWorkspaceReference(
            adapterIdentifier: model.adapter.displayName.lowercased(),
            workspaceIdentifier: session.workspace
        )
        let room = await model.roomStore.resolvedRoom(workspace: workspace, hostAlias: session.host)
        publications.append(
            AdapterSessionPublication(
                session: session,
                target: Target(room: room.id),
                adapterHealth: model.adapterHealth,
                control: model.adapter.capabilities.teleport ? .available : .unavailable
            )
        )
    }
    let snapshot = await model.surfaces.ingest(adapterSessions: publications)
    state.adapterSessionsByRecord = matchAdapterSessions(sessions, records: snapshot.records)
    await projectSurfaceSnapshot(for: model, force: true)
}

private func matchAdapterSessions(
    _ sessions: [AdapterSession],
    records: [NormalizedRecord]
) -> [RecordID: AdapterSession] {
    var result: [RecordID: AdapterSession] = [:]
    for record in records where record.source == .adapterAssociated {
        let matches = sessions.filter {
            $0.title == record.title && $0.host == record.host && $0.workspace == record.workspace
        }
        if matches.count == 1 { result[record.id] = matches[0] }
    }
    return result
}

private func surfaceMutationKey() -> IdempotencyKey {
    IdempotencyKey(rawValue: UUID().uuidString)
}

private func routerItemHasLowerPriority(_ lhs: RouterItem, _ rhs: RouterItem) -> Bool {
    let left = RouterReducer.priority(lhs.attentionClass)
    let right = RouterReducer.priority(rhs.attentionClass)
    if left != right { return left < right }
    return lhs.id.description < rhs.id.description
}
