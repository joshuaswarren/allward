import AllwardCore
import AllwardDesign
import SwiftUI

@MainActor
public struct BoardView: View {
    @Environment(\.allwardPalette) private var palette
    @State private var query = ""
    @State private var selectedID: RecordID?
    @State private var pendingTeleportID: RecordID?
    @FocusState private var filterFocused: Bool

    public let state: BoardViewState
    public let onOpenDetails: @MainActor (BoardViewState.Row) -> Void
    public let onTeleport: @MainActor (BoardViewState.Row) -> Void
    public let onAcknowledgeLocally: @MainActor (BoardViewState.Row) -> Void
    public let onPublisherDecision: @MainActor (BoardViewState.Row, String) -> Void
    public let onBoardAction: @MainActor (String) -> Void
    public let onDismiss: @MainActor () -> Void

    public init(
        state: BoardViewState,
        onOpenDetails: @escaping @MainActor (BoardViewState.Row) -> Void = { _ in },
        onTeleport: @escaping @MainActor (BoardViewState.Row) -> Void = { _ in },
        onAcknowledgeLocally: @escaping @MainActor (BoardViewState.Row) -> Void = { _ in },
        onPublisherDecision: @escaping @MainActor (BoardViewState.Row, String) -> Void = { _, _ in },
        onBoardAction: @escaping @MainActor (String) -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.onOpenDetails = onOpenDetails
        self.onTeleport = onTeleport
        self.onAcknowledgeLocally = onAcknowledgeLocally
        self.onPublisherDecision = onPublisherDecision
        self.onBoardAction = onBoardAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        SurfacePanel(
            title: "Board",
            accessibilityTitle: "Board, \(filteredRowCount) items",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: onDismiss
        ) {
            VStack(alignment: .leading, spacing: SpaceToken.section.points) {
                filterField
                stateNotice
                if state.state != .noSessions {
                    columnHeader
                    boardContent
                }
                if let lockedRow {
                    teleportConfirmation(for: lockedRow)
                }
            }
            .frame(maxHeight: state.state == .noSessions ? nil : .infinity, alignment: .top)
        }
        .frame(maxHeight: state.state == .noSessions ? nil : .infinity, alignment: .top)
        .onAppear {
            selectedID = visibleRows.first?.id
        }
        .onChange(of: visibleRows.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            self.selectedID = ids.first
        }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    private var filterField: some View {
        TextField("Filter sessions", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                filterFocused = false
                selectedID = visibleRows.first?.id
            }
            .focused($filterFocused)
            .tokenFont(.uiBody, palette)
            .accessibilityLabel("Filter Board sessions")
            .accessibilitySortPriority(10)
    }

    @ViewBuilder
    private var stateNotice: some View {
        switch state.state {
        case .loading:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                LoadingStateView(
                    target: state.subject.target,
                    step: state.inventoryStep ?? state.subject.boundedStep ?? "Inventory attempt in progress",
                    cancel: { onBoardAction("cancel-inventory") })
                Button("Inspect connection") { onBoardAction("inspect-connection") }
            }
        case .noSessions:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                SectionHeader(state.subject.target)
                EmptyStateView(
                    title: "No sessions yet",
                    reason: "Choose how to start: local terminal, direct SSH, or a configured adapter.")
                HStack(spacing: SpaceToken.inlineStandard.points) {
                    Button("Create local terminal") { onBoardAction("create-local-terminal") }
                    Button("Connect SSH") { onBoardAction("connect-ssh") }
                    Button("Choose configured adapter") { onBoardAction("choose-adapter") }
                }
            }
        case .noOpenLoops:
            EmptyStateView(
                title: "No open loops published",
                reason: "All sessions remain available. Published open loops are optional.",
                actionTitle: "Show all sessions",
                action: { onBoardAction("show-all-sessions") })
        case .error:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                ErrorStateView(
                    operation: state.subject.failedOperation ?? "Refresh Board source",
                    target: state.subject.target,
                    cause: state.subject.reason ?? "The source did not return an inventory update.",
                    recovery: state.subject.recovery ?? "Retry the source or open diagnostics.",
                    retry: { onBoardAction("retry-source") })
                Button("Open diagnostics") { onBoardAction("open-diagnostics") }
            }
        case .staleOrDegraded:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                HStack(spacing: SpaceToken.inlineStandard.points) {
                    Button("Reconnect affected source") { onBoardAction("reconnect-source") }
                    Button("Inspect affected source") { onBoardAction("inspect-source") }
                }
            }
        case .permission:
            HStack(spacing: SpaceToken.inlineStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                Text("Review the exact publisher request below. Return never implies approval.")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        case .maximumContent:
            HStack(spacing: SpaceToken.inlineStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                Text("Showing \(visibleRows.count) of \(filteredRowCount) sessions")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        case .zeroPublishers, .populated:
            EmptyView()
        }
    }

    private var stateColumnWidth: Double {
        SpaceToken.section.points * 9
    }

    private var sessionColumnWidth: Double {
        SpaceToken.section.points * 12
    }

    private var openLoopsColumnWidth: Double {
        SpaceToken.section.points * 7
    }

    private var freshnessColumnWidth: Double {
        SpaceToken.section.points * 8
    }
    private var boardContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SpaceToken.section.points) {
                ForEach(filteredGroups) { group in
                    roomGroup(group)
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Board, \(filteredRowCount) items")
        .accessibilitySortPriority(80)
    }

    private func roomGroup(_ group: BoardViewState.RoomGroup) -> some View {
        HStack(alignment: .top, spacing: SpaceToken.blockStandard.points) {
            RoomSeam(roomTint: group.roomTint)
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                SectionHeader(group.roomName, count: group.hostWorkspaces.flatMap(\.rows).count)
                ForEach(group.hostWorkspaces) { hostWorkspace in
                    hostWorkspaceGroup(hostWorkspace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hostWorkspaceGroup(_ group: BoardViewState.HostWorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text(group.host)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(.textPrimary, palette)
                Text(group.workspace)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(group.workspace)
            }
            ForEach(group.rows.filter(rowMatchesQuery)) { row in
                boardRow(row)
                if selectedID == row.id {
                    rowActions(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpaceToken.blockStandard.points) {
            Text("State")
                .frame(width: stateColumnWidth, alignment: .leading)
            Text("Session")
                .frame(width: sessionColumnWidth, alignment: .leading)
            if state.publisherColumnsPresent {
                Text("Open loops")
                    .frame(width: openLoopsColumnWidth, alignment: .leading)
            }
            Text("Freshness")
                .frame(width: freshnessColumnWidth, alignment: .leading)
            Text("Destination")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, StrokeToken.roomSeam.width(palette.settings) + SpaceToken.blockStandard.points)
        .tokenFont(.uiCaption, palette)
        .tokenForeground(.textSecondary, palette)
        .accessibilityHidden(true)
    }

    private func boardRow(_ row: BoardViewState.Row) -> some View {
        HStack(alignment: .top, spacing: SpaceToken.blockStandard.points) {
            StateBadge(presentation: row.presentation, subject: row.subject)
                .frame(width: stateColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                Text(row.sessionTitle)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(row.sessionTitle)
                if state.publisherColumnsPresent {
                    Text(row.provenanceLabel)
                        .tokenFont(.uiCaption, palette)
                        .tokenForeground(.textSecondary, palette)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(row.provenanceLabel)
                }
            }
            .frame(width: sessionColumnWidth, alignment: .leading)
            if state.publisherColumnsPresent {
                Text("\(row.openLoopCount)")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textPrimary, palette)
                    .accessibilityLabel("\(row.openLoopCount) open loops")
                    .frame(width: openLoopsColumnWidth, alignment: .leading)
            }
            FreshnessLabel(age: row.freshnessAge, presentation: row.presentation, subject: row.subject)
                .frame(width: freshnessColumnWidth, alignment: .leading)
            if let destinationKey = row.destinationKey {
                DestinationKeyCap(key: destinationKey, target: row.subject.target)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No key")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .accessibilityLabel("No destination key")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpaceToken.blockCompact.points)
        .background {
            if selectedID == row.id {
                RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                    .fill(palette[.selectionNative].swiftUIColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedID = row.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(row.roomName), \(row.sessionTitle), \(row.host), \(row.workspace), \(row.provenanceLabel)")
        .accessibilityValue(row.presentation.accessibilityValue(row.subject))
        .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
        .accessibilityAction(named: "Open details") { onOpenDetails(row) }
        .accessibilityAction(named: "Teleport") { pendingTeleportID = row.id }
    }

    private func rowActions(_ row: BoardViewState.Row) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Button("Open details") { onOpenDetails(row) }
                    .accessibilityValue(row.presentation.accessibilityValue(row.subject))
                Button("Teleport") { pendingTeleportID = row.id }
                    .accessibilityValue(row.presentation.accessibilityValue(row.subject))
            }
            if row.locallyAcknowledgeable {
                VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                    Button("Acknowledge locally") { onAcknowledgeLocally(row) }
                        .buttonStyle(.borderless)
                        .accessibilityValue("Local router epoch only; publisher state unchanged")
                        .accessibilityHint(
                            "Closes only this Allward router attention epoch. "
                                + "It does not approve the publisher request.")
                    Label("Local only", systemImage: "checkmark.circle")
                        .tokenFont(.uiCaption, palette)
                        .tokenForeground(.textSecondary, palette)
                }
            }
            if state.publisherColumnsPresent, let decision = row.permissionDecision {
                publisherDecision(decision, row: row)
            }
        }
        .padding(.leading, SpaceToken.section.points)
        .padding(.bottom, SpaceToken.blockStandard.points)
    }

    private func canShowPublisherDecision(for row: BoardViewState.Row) -> Bool {
        state.publisherColumnsPresent
            && row.publisherDecisionActionable
            && row.presentation.usability.permitsApproval
            && !row.presentation.controlDisabled
    }

    @ViewBuilder
    private func publisherDecision(
        _ decision: BoardViewState.PermissionDecision,
        row: BoardViewState.Row
    ) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
            SectionHeader("Publisher decision")
            Text("\(decision.publisher) • \(row.roomName) / \(row.sessionTitle)")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
            if let expiryLabel = decision.expiryLabel {
                Text(expiryLabel)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
            }
            switch decision.state {
            case .ready:
                if canShowPublisherDecision(for: row) {
                    HStack(spacing: SpaceToken.inlineStandard.points) {
                        ForEach(decision.options) { option in
                            Button(option.verb) { onPublisherDecision(row, option.id) }
                                .buttonStyle(.bordered)
                                .accessibilityValue(row.presentation.accessibilityValue(row.subject))
                                .accessibilityHint(
                                    "\(decision.publisher), \(row.roomName) / \(row.sessionTitle)")
                        }
                    }
                } else {
                    StateBadge(presentation: row.presentation, subject: row.subject)
                }
            case .dispatching(let option):
                Text("Sending \(option) to \(decision.publisher)")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                if canShowPublisherDecision(for: row), decision.cancellable {
                    Button("Cancel decision") { onPublisherDecision(row, "cancel") }
                        .accessibilityValue(row.presentation.accessibilityValue(row.subject))
                }
            case .accepted:
                Text("Decision accepted — awaiting publisher commit")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
            case .committed:
                let mark = StateMark.mark(for: .finished)
                Label("Granted", systemImage: mark.symbolName)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(mark.color, palette)
                Text("Decision committed")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                if let effectReceipt = decision.effectReceipt {
                    Text(effectReceipt)
                        .tokenFont(.uiData, palette)
                        .tokenForeground(.textSecondary, palette)
                }
            case .rejected(let reason):
                Text("Decision rejected by publisher")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.stateError, palette)
                Text(reason)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
                Button("Review publisher state") { onOpenDetails(row) }
            case .cancelled:
                Text("Decision cancelled — not committed")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
            case .acknowledged(let outcome, let receipt):
                Text("Publisher acknowledged \(outcome)")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                Text(receipt)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
            case .outcomeUnknown(let transaction):
                Text("Decision result unknown — checking publisher")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.stateStale, palette)
                Text("\(transaction) • \(row.roomName) / \(row.sessionTitle)")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func teleportConfirmation(for row: BoardViewState.Row) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Divider()
                .overlay(palette[.strokeDivider].swiftUIColor)
            Label("Destination locked", systemImage: "lock.fill")
                .tokenFont(.uiTitle, palette)
                .tokenForeground(.textPrimary, palette)
            Text("\(row.roomName) / \(row.host) / \(row.workspace) / \(row.sessionTitle)")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityLabel(
                    "Locked destination: \(row.roomName), \(row.host), \(row.workspace), \(row.sessionTitle)")
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Button("Cancel") { pendingTeleportID = nil }
                Button("Teleport to destination") {
                    pendingTeleportID = nil
                    onTeleport(row)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var lockedRow: BoardViewState.Row? {
        guard let pendingTeleportID else { return nil }
        return allRows.first { $0.id == pendingTeleportID }
    }

    private var allRows: [BoardViewState.Row] {
        state.groups.flatMap(\.hostWorkspaces).flatMap(\.rows)
    }

    private var filteredRowCount: Int {
        allRows.filter(rowMatchesQuery).count
    }

    private var visibleRows: [BoardViewState.Row] {
        let rows = allRows.filter(rowMatchesQuery)
        return Array(rows.prefix(state.maximumVisibleRows))
    }

    private var filteredGroups: [BoardViewState.RoomGroup] {
        var remaining = state.maximumVisibleRows
        return state.groups.compactMap { group in
            let hostWorkspaces: [BoardViewState.HostWorkspaceGroup] = group.hostWorkspaces.compactMap {
                hostWorkspace in
                guard remaining > 0 else { return nil }
                let rows = hostWorkspace.rows.filter(rowMatchesQuery)
                let visible = Array(rows.prefix(remaining))
                remaining -= visible.count
                guard !visible.isEmpty else { return nil }
                return BoardViewState.HostWorkspaceGroup(
                    host: hostWorkspace.host, workspace: hostWorkspace.workspace, rows: visible)
            }
            guard !hostWorkspaces.isEmpty else { return nil }
            return BoardViewState.RoomGroup(
                roomName: group.roomName, roomTint: group.roomTint,
                hostWorkspaces: hostWorkspaces)
        }
    }

    private func rowMatchesQuery(_ row: BoardViewState.Row) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.localizedLowercase
        return [row.roomName, row.sessionTitle, row.host, row.workspace, row.provenanceLabel]
            .contains { $0.localizedLowercase.contains(needle) }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !filterFocused else { return .ignored }
        if press.key == .upArrow {
            moveSelection(by: -1)
            return .handled
        }
        if press.key == .downArrow {
            moveSelection(by: 1)
            return .handled
        }
        if press.key == .return || press.key == .rightArrow {
            guard let row = selectedRow else { return .ignored }
            if pendingTeleportID == row.id {
                pendingTeleportID = nil
                onTeleport(row)
            } else {
                onOpenDetails(row)
            }
            return .handled
        }
        switch press.characters.lowercased() {
        case "t":
            guard let row = selectedRow else { return .ignored }
            pendingTeleportID = row.id
            return .handled
        case "a":
            guard let row = selectedRow, row.locallyAcknowledgeable else { return .ignored }
            onAcknowledgeLocally(row)
            return .handled
        case "n":
            selectNextActionable()
            return .handled
        case "r":
            jumpToNextRoom()
            return .handled
        default:
            let destination = press.characters
            guard Int(destination) != nil,
                  let row = visibleRows.first(where: { $0.destinationKey == destination })
            else { return .ignored }
            selectedID = row.id
            pendingTeleportID = row.id
            return .handled
        }
    }

    private func selectNextActionable() {
        let actionable = visibleRows.filter {
            $0.locallyAcknowledgeable
                || $0.publisherDecisionActionable
                || $0.presentation.state == .error
                || $0.presentation.state == .needsInput
        }
        guard !actionable.isEmpty else { return }
        let current = actionable.firstIndex { $0.id == selectedID } ?? -1
        selectedID = actionable[(current + 1) % actionable.count].id
    }

    private func jumpToNextRoom() {
        let roomRows = filteredGroups.map { $0.hostWorkspaces.flatMap(\.rows) }.filter { !$0.isEmpty }
        guard !roomRows.isEmpty else { return }
        let currentRoom = roomRows.firstIndex { rows in rows.contains { $0.id == selectedID } } ?? -1
        selectedID = roomRows[(currentRoom + 1) % roomRows.count].first?.id
    }

    private var selectedRow: BoardViewState.Row? {
        guard let selectedID else { return nil }
        return visibleRows.first { $0.id == selectedID }
    }

    private func moveSelection(by offset: Int) {
        guard !visibleRows.isEmpty else { return }
        let current = visibleRows.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + offset, 0), visibleRows.count - 1)
        selectedID = visibleRows[next].id
    }
}

#Preview("Board populated") {
    BoardView(state: .fixture())
        .frame(width: 980, height: 720)
        .padding(SpaceToken.section.points)
        .allwardPalette(DesignPalette(appearance: .dark))
}

#Preview("Board without publishers") {
    BoardView(state: .fixture(state: .zeroPublishers, publisherColumnsPresent: false))
        .frame(width: 840, height: 640)
        .padding(SpaceToken.section.points)
        .allwardPalette(DesignPalette(appearance: .light))
}
