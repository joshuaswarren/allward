import AllwardConfig
import AllwardControl
import AllwardCore
import AllwardDesign
import AllwardRooms
import AllwardSurfaces
import Foundation
import SwiftUI

@MainActor
extension MainWindowController {
    public func presentFind() {
        present(
            .find,
            content: FindView(
                matchCount: model.searchMatchCount,
                currentMatch: model.currentSearchMatch,
                onQueryChanged: { [weak model] query in
                    Task { await model?.search(for: query) }
                },
                onNext: { [weak self] in Task { await self?.stepSearch(forward: true) } },
                onPrevious: { [weak self] in Task { await self?.stepSearch(forward: false) } },
                onDismiss: { [weak self] in self?.dismissSummonedSurface() }
            ))
    }

    /// Re-presents so the match tally stays truthful as it changes.
    private func stepSearch(forward: Bool) async {
        await model.stepSearchMatch(forward: forward)
        if presentedSurface == .find { presentFind() }
    }

    public func presentBoard() {
        guard let state = model.boardState else {
            model.lastActionMessage = "Board data has not loaded yet."
            Task { [weak self] in
                guard let self else { return }
                await model.refreshSurfaceProjection()
                if model.boardState != nil { presentBoard() }
            }
            return
        }
        present(
            .board,
            content: BoardView(
                state: state,
                onOpenDetails: { [weak self] row in
                    guard let self else { return }
                    dismissSummonedSurface()
                    Task { await openSurfaceRecord(row.id, model: model) }
                },
                onTeleport: { [weak self] row in
                    guard let self else { return }
                    dismissSummonedSurface()
                    Task { await openSurfaceRecord(row.id, model: model) }
                },
                onAcknowledgeLocally: { [weak self] row in
                    guard let self else { return }
                    Task {
                        await acknowledgeSurfaceRecord(row.id, model: model)
                        presentBoard()
                    }
                },
                onBoardAction: { [weak self] action in self?.performBoardAction(action) },
                onDismiss: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    public func presentDigest() {
        guard let state = model.digestState else {
            model.lastActionMessage = "Digest data has not loaded yet."
            Task { [weak self] in
                guard let self else { return }
                await model.refreshSurfaceProjection()
                if model.digestState != nil { presentDigest() }
            }
            return
        }
        present(
            .digest,
            content: DigestView(
                state: state,
                onOpenSource: { [weak self] index in
                    guard let self else { return }
                    dismissSummonedSurface()
                    Task { await openDigestSource(index, model: model) }
                },
                onAcknowledge: { [weak self] in
                    guard let self else { return }
                    Task {
                        await acknowledgeDigest(model: model)
                        presentDigest()
                    }
                },
                onDismiss: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    public func presentCommandPalette() {
        let state = SurfaceProjection.commandPalette(
            query: "",
            rooms: model.rooms,
            hosts: model.configuration.hosts,
            canSplit: model.focusedPane != nil,
            canClose: model.focusedPane != nil
        )
        present(
            .commandPalette,
            content: CommandPaletteView(
                state: state,
                onQueryChanged: { [weak self] _ in self?.model.lastActionMessage = nil },
                onSubmit: { [weak self] command in
                    guard let self else { return }
                    dismissSummonedSurface()
                    performPaletteCommand(command)
                },
                dismissAndRestoreInvocation: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    public func presentSettings() {
        let state = SurfaceProjection.settings(
            model.configuration,
            rooms: model.rooms,
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: model.adapterHealth,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133",
            selectedTab: model.selectedSettingsTab
        )
        present(
            .settings,
            content: SettingsView(
                state: state,
                onUpdate: { [weak self] update in
                    guard let self else { return }
                    Task { await model.applySettingsUpdate(update) }
                },
                dismissAndRestoreInvocation: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    public func presentDiagnostics() {
        Task { [weak self] in
            guard let self else { return }
            let state = await diagnosticsState()
            present(
                .diagnostics,
                content: DiagnosticsView(
                    state: state,
                    dismissAndRestoreInvocation: { [weak self] in self?.dismissSummonedSurface() }
                )
            )
        }
    }

    public func presentRoomSwitcher() {
        let entries = model.rooms.map { room in
            SelectionEntry(
                id: room.id.rawValue.uuidString.lowercased(),
                title: room.name,
                detail: room.hostAliases.isEmpty
                    ? "Local sessions"
                    : "\(room.hostAliases.count) configured hosts",
                tint: room.baseTint
            )
        }
        present(
            .roomSwitcher,
            content: SelectionSurfaceView(
                title: "Switch Room",
                emptyReason: "No Rooms are configured.",
                entries: entries,
                onSelect: { [weak self] entry in
                    guard let self,
                          let id = UUID(uuidString: entry.id) else { return }
                    dismissSummonedSurface()
                    Task { await switchRoom(RoomID(rawValue: id), model: model) }
                },
                onDismiss: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    public func presentHostPicker() {
        let entries = model.configuration.hosts.map { host in
            let prefix = host.user.map { "\($0)@" } ?? ""
            return SelectionEntry(
                id: host.alias.rawValue,
                title: host.alias.rawValue,
                detail: "\(prefix)\(host.hostname):\(host.port)",
                tint: nil
            )
        }
        present(
            .hostPicker,
            content: SelectionSurfaceView(
                title: "Connect to SSH host",
                emptyReason: "No SSH hosts are configured.",
                entries: entries,
                onSelect: { [weak self] entry in
                    guard let self else { return }
                    dismissSummonedSurface()
                    Task { await model.newSSHPane(host: HostAlias(rawValue: entry.id)) }
                },
                onDismiss: { [weak self] in self?.dismissSummonedSurface() }
            )
        )
    }

    private func performBoardAction(_ action: String) {
        switch action {
        case "create-local-terminal":
            dismissSummonedSurface()
            Task { await model.newLocalPane() }
        case "connect-ssh":
            presentHostPicker()
        case "open-diagnostics", "inspect-connection", "inspect-source":
            presentDiagnostics()
        default:
            model.lastActionMessage = "Board action \(action) is not available."
        }
    }

    private func performPaletteCommand(_ command: PaletteCommand) {
        switch command.id {
        case "session.new-local": Task { await model.newLocalPane() }
        case "window.new": Task { await model.openNewWindow() }
        case "pane.close": Task { await model.closeFocusedPane() }
        case "pane.split-right": Task { await model.splitFocusedPane(.horizontal) }
        case "pane.split-down": Task { await model.splitFocusedPane(.vertical) }
        case "host.connect": presentHostPicker()
        case "surface.board": presentBoard()
        case "surface.digest": presentDigest()
        case "surface.command-palette": presentCommandPalette()
        case "room.switcher": presentRoomSwitcher()
        case "teleport": Task { await model.teleportToRoutedDestination() }
        case "settings.open": presentSettings()
        case "diagnostics.open": presentDiagnostics()
        default: model.lastActionMessage = "Command \(command.title) is no longer available."
        }
    }


    private func diagnosticsState() async -> DiagnosticsViewState {
        let snapshot = await model.surfaces.snapshot()
        let inputs = model.diagnosticsInputs
        let live = ComposedPresentation(state: .live, usability: .usableActionCapable)
        let unavailable = ComposedPresentation(state: .empty, usability: .closedAbsent)
        let adapterPresentation: ComposedPresentation = switch inputs.adapterHealth {
        case .available:
            live
        case .degraded:
            ComposedPresentation(state: .degraded, usability: .staleNonactionable)
        case .denied:
            ComposedPresentation(state: .denied, usability: .usableControlDisabled)
        case .error:
            ComposedPresentation(state: .error, usability: .errorRecoveryOnly)
        case .none:
            unavailable
        }
        let tally = inputs.protocolTally
        let accepted = UInt64(max(0, tally.accepted))
        let ignoredUnknown = UInt64(max(0, tally.ignoredUnknownFrames))
        let duplicates = UInt64(max(0, tally.duplicateSequences))
        let rejected = UInt64(max(0, tally.rejectedBounds))
        let superseded = UInt64(max(0, tally.staleEpochs))
        var ignoredReasons: [ReasonCount] = []
        if ignoredUnknown > 0 {
            ignoredReasons.append(
                ReasonCount(id: "unknown-frame", reason: "Unknown frame", count: ignoredUnknown))
        }
        if duplicates > 0 {
            ignoredReasons.append(
                ReasonCount(id: "duplicate-sequence", reason: "Duplicate sequence", count: duplicates))
        }
        let rejectedReasons = rejected > 0
            ? [ReasonCount(id: "bounded-payload", reason: "Bounded payload exceeded", count: rejected)]
            : []
        let publisher = inputs.publisherEndpointPath ?? "Publisher endpoint not listening"
        let leasePresentation = inputs.publisherEndpointPath == nil ? unavailable : live
        let activeTarget = model.activeRoom?.name ?? "No active Room"
        let connectionPresentation = model.topology.panes.isEmpty ? unavailable : live
        let connectionCause = inputs.lastConnectionCause.map(ConnectionCause.retryable)
        let occupancy = max(
            inputs.renderer.monochromeAtlasOccupancy,
            inputs.renderer.colorAtlasOccupancy
        )
        let protocolCounters = ProtocolCounters(
            accepted: accepted,
            ignored: ignoredUnknown + duplicates,
            rejected: rejected,
            superseded: superseded
        )
        let fields: [DiagnosticsExportField] = [
            .rendererBackendMetal,
            .protocolAccepted(protocolCounters.accepted),
            .protocolIgnored(protocolCounters.ignored),
            .protocolRejected(protocolCounters.rejected),
            .protocolSuperseded(protocolCounters.superseded),
            .rendererFrames(UInt64(max(0, inputs.renderer.framesSubmitted))),
            .atlasGeneration(inputs.renderer.atlasGeneration),
            .atlasOccupancyPercent(occupancy)
        ]
        return SurfaceProjection.diagnostics(
            presentation: live,
            subject: PresentationSubject(componentName: "Diagnostics", target: "Allward runtime"),
            protocolCounters: protocolCounters,
            ignoredReasons: ignoredReasons,
            rejectedReasons: rejectedReasons,
            lease: LeaseDiagnostic(
                publisher: publisher,
                generation: snapshot.generation,
                expiresIn: nil,
                presentation: leasePresentation,
                subject: PresentationSubject(
                    componentName: "Publisher endpoint",
                    target: publisher,
                    reason: "\(inputs.activePublishers) active publishers")
            ),
            adapter: AdapterDiagnostic(
                name: model.adapter.displayName,
                route: inputs.adapterRoute ?? "No adapter route",
                reason: inputs.adapterRouteReason,
                presentation: adapterPresentation,
                subject: PresentationSubject(
                    componentName: "Adapter",
                    target: model.adapter.displayName,
                    reason: inputs.adapterRouteReason)
            ),
            connection: ConnectionDiagnostic(
                target: activeTarget,
                attempt: inputs.connectionAttempts,
                maximumAttempts: AttemptBound.connect.maxAttempts,
                lastCause: connectionCause,
                presentation: connectionPresentation,
                subject: PresentationSubject(componentName: "Connection", target: activeTarget)
            ),
            renderer: RendererDiagnostic(
                framesSubmitted: UInt64(max(0, inputs.renderer.framesSubmitted)),
                atlasGeneration: inputs.renderer.atlasGeneration,
                atlasOccupancyPercent: occupancy,
                presentation: live,
                subject: PresentationSubject(componentName: "Renderer", target: "Metal renderer")
            ),
            mcpGrants: [],
            safeExportFields: fields,
            exportFileName: "allward-diagnostics-\(snapshot.generation.rawValue).txt",
            exportEnabled: !fields.isEmpty
        )
    }
}


private struct SelectionEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let tint: TokenColor?
}

@MainActor
private struct SelectionSurfaceView: View {
    @Environment(\.allwardPalette) private var palette
    @FocusState private var listFocused: Bool
    @State private var selectedIndex = 0

    let title: String
    let emptyReason: String
    let entries: [SelectionEntry]
    let onSelect: @MainActor (SelectionEntry) -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        let available = !entries.isEmpty
        SurfacePanel(
            title: title,
            accessibilityTitle: "\(title), \(entries.count) options",
            presentation: ComposedPresentation(
                state: available ? .live : .empty,
                usability: available ? .usableActionCapable : .closedAbsent
            ),
            subject: PresentationSubject(
                componentName: title,
                target: available ? "Configured choices" : emptyReason,
                reason: available ? nil : emptyReason
            ),
            onDismiss: onDismiss,
            focusTitleOnAppear: false
        ) {
            if entries.isEmpty {
                EmptyStateView(title: "Nothing configured", reason: emptyReason)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
                        ForEach(entries.indices, id: \.self) { index in
                            row(entries[index], selected: index == selectedIndex)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onAppear { listFocused = true }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard entries.indices.contains(selectedIndex) else { return .ignored }
            onSelect(entries[selectedIndex])
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func row(_ entry: SelectionEntry, selected: Bool) -> some View {
        Button {
            selectedIndex = entries.firstIndex(of: entry) ?? 0
            onSelect(entry)
        } label: {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                if let tint = entry.tint {
                    Circle()
                        .fill(tint.swiftUIColor)
                        .frame(width: SpaceToken.section.points, height: SpaceToken.section.points)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                    Text(entry.title)
                        .font(palette.type(.uiBody).swiftUIFont)
                        .foregroundStyle(palette[.textPrimary].swiftUIColor)
                    Text(entry.detail)
                        .font(palette.type(.uiCaption).swiftUIFont)
                        .foregroundStyle(palette[.textSecondary].swiftUIColor)
                }
                Spacer(minLength: SpaceToken.inlineStandard.points)
            }
            .padding(.horizontal, SpaceToken.blockStandard.points)
            .padding(.vertical, SpaceToken.blockCompact.points)
            .background(selected ? palette[.selectionNative].swiftUIColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                        .strokeBorder(
                            palette[.strokeKeyboardFocus].swiftUIColor,
                            lineWidth: StrokeToken.keyboardFocus.width(palette.settings)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : entry.detail)
    }

    private func moveSelection(by offset: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + entries.count) % entries.count
    }
}
