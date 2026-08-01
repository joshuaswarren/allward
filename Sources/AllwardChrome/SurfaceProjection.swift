import AllwardConfig
import AllwardCore
import AllwardDesign
import AllwardProtocol
import AllwardRooms
import AllwardSurfaces
import Foundation

public enum SurfaceProjection {
    public static func board(
        _ snapshot: BoardSnapshot,
        rooms: [Room],
        now: Date,
        palette: DesignPalette
    ) -> BoardViewState {
        let roomLookup = indexRooms(rooms)
        let fallbackTint = palette[.stateStale]
        var roomGroups: [BoardViewState.RoomGroup] = []
        for group in snapshot.groups {
            let room = roomLookup[group.roomID]
            let rows = group.rows.map { boardRow($0, room: room, now: now, fallbackTint: fallbackTint) }
            let hostWorkspace = BoardViewState.HostWorkspaceGroup(
                host: group.host?.rawValue ?? "Local",
                workspace: group.workspace ?? "",
                rows: rows
            )
            let roomName = room?.name ?? "Room \(group.roomID.shortLabel)"
            if let index = roomGroups.firstIndex(where: { $0.roomName == roomName }) {
                roomGroups[index].hostWorkspaces.append(hostWorkspace)
            } else {
                roomGroups.append(BoardViewState.RoomGroup(
                    roomName: roomName,
                    roomTint: room?.baseTint ?? fallbackTint,
                    hostWorkspaces: [hostWorkspace]
                ))
            }
        }
        let rows = snapshot.groups.flatMap(\.rows)
        let firstRow = rows.first
        let presentation = boardFallbackPresentation(snapshot.state)
        return BoardViewState(
            state: boardState(snapshot.state),
            presentation: presentation,
            subject: boardSubject(snapshot: snapshot, firstRow: firstRow, now: now),
            groups: roomGroups,
            publisherColumnsPresent: rows.contains { $0.publisher != nil },
            inventoryStep: snapshot.state == .loading ? "Loading session inventory" : nil,
            maximumVisibleRows: snapshot.visibleRowCount
        )
    }

    public static func router(
        _ snapshot: RouterSnapshot,
        rooms: [Room],
        now: Date,
        activeRoom: Room? = nil
    ) -> RouterViewState {
        let roomLookup = indexRooms(rooms)
        let items = snapshot.items.map { item in
            let presentation = PresentationComposer.compose(item.composition)
            return RouterViewState.Item(
                id: item.id,
                attentionClass: item.attentionClass,
                presentation: presentation,
                composition: item.composition,
                subject: recordSubject(
                    componentName: "Router item",
                    target: item.target,
                    title: item.title,
                    detail: nil,
                    source: item.source,
                    composition: item.composition,
                    freshness: item.freshness,
                    now: now
                ),
                roomName: roomLookup[item.roomID]?.name ?? "Room \(item.roomID.shortLabel)",
                destinationKey: item.destinationKey,
                provenanceLabel: sourceLabel(item.source)
            )
        }
        // With nothing actionable the router still belongs to the window's
        // Room; falling back to "No room" would state something untrue.
        let selectedRoomID = snapshot.roomID ?? snapshot.items.first?.roomID
        let selectedRoom = selectedRoomID.flatMap { roomLookup[$0] } ?? activeRoom
        let selectedItem = snapshot.items.first { !$0.isLocallyAcknowledged }
        let presentation = routerFallbackPresentation(snapshot.state)
        return RouterViewState(
            presentation: presentation,
            subject: routerSubject(snapshot: snapshot, selectedItem: selectedItem, now: now),
            highestClass: snapshot.highestPriorityClass,
            actionableCount: snapshot.totalActionableCount,
            roomName: selectedRoom?.name
                ?? selectedRoomID.map { "Room \($0.shortLabel)" } ?? "",
            roomTint: selectedRoom?.baseTint ?? TokenColor(0, 0, 0, alpha: 0),
            freshnessAge: snapshot.freshness?.age(at: now) ?? 0,
            destinationKey: snapshot.destinationKey,
            items: items,
            newEpochs: snapshot.newEpochs,
            focusFiltered: routerIsFocusFiltered(snapshot.state),
            zeroState: routerZeroState(snapshot.state)
        )
    }

    public static func digest(
        _ snapshot: DigestSnapshot,
        rooms: [Room],
        now: Date
    ) -> DigestViewState {
        let roomLookup = indexRooms(rooms)
        let facts = snapshot.facts.map { fact in
            let presentation = PresentationComposer.compose(fact.composition)
            return DigestViewState.Fact(
                id: fact.id,
                text: fact.lines.joined(separator: "\n"),
                target: fact.sourceLink.target.description,
                roomName: roomLookup[fact.roomID]?.name ?? "Room \(fact.roomID.shortLabel)",
                sessionTitle: fact.title,
                sourceLabel: sourceLabel(fact.sourceLink.source),
                sourceRecordID: fact.sourceLink.recordID,
                sourceCommandID: fact.sourceLink.commandID,
                freshnessAge: fact.freshness.age(at: now),
                presentation: presentation,
                composition: fact.composition,
                subject: recordSubject(
                    componentName: "Digest fact",
                    target: fact.sourceLink.target,
                    title: fact.title,
                    detail: fact.staleReason ?? fact.lines.first,
                    source: fact.sourceLink.source,
                    composition: fact.composition,
                    freshness: fact.freshness,
                    now: now
                )
            )
        }
        let firstFact = snapshot.facts.first
        let presentation = digestFallbackPresentation(snapshot.state)
        return DigestViewState(
            allowedUnseenEventCount: snapshot.allowedUnseenEventCount,
            orderedFacts: facts,
            state: digestState(snapshot.state, facts: snapshot.facts),
            presentation: presentation,
            subject: digestSubject(snapshot: snapshot, firstFact: firstFact, now: now)
        )
    }

    public static func settings(
        _ configuration: Configuration,
        rooms: [Room],
        themes: [String],
        adapterHealth: AdapterHealth,
        mcpCommandLine: String,
        shellLane: String,
        selectedTab: SettingsTab = .general
    ) -> SettingsViewState {
        let themeNames = unique([configuration.terminal.theme] + rooms.map(\.terminalThemeName) + themes)
        let themeChoices = themeNames.map { SettingChoice(id: $0, label: $0) }
        let tintChoices = roomTintChoices(rooms)
        return SettingsViewState(
            presentation: PresentationComposer.compose(.liveLocal),
            subject: PresentationSubject(componentName: "Settings", target: "Allward settings"),
            selectedTab: selectedTab,
            general: generalSettings(configuration, shellLane: shellLane),
            appearance: appearanceSettings(configuration),
            sound: soundSettings(configuration),
            rooms: rooms.map { roomSetting($0, themes: themeChoices, tintChoices: tintChoices) },
            themes: themeNames.map {
                ThemeSetting(
                    id: $0,
                    name: $0,
                    appearance: themeAppearance($0),
                    isBuiltIn: ThemeCatalog.theme(named: $0) != nil,
                    isSelected: $0 == configuration.terminal.theme
                )
            },
            themeImports: [],
            keys: keySettings(configuration.dictationKey),
            integrations: integrationSettings(
                configuration: configuration,
                adapterHealth: adapterHealth,
                mcpCommandLine: mcpCommandLine
            ),
            privacy: privacySettings
        )
    }

    public static func diagnostics(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        protocolCounters: ProtocolCounters,
        ignoredReasons: [ReasonCount],
        rejectedReasons: [ReasonCount],
        lease: LeaseDiagnostic,
        adapter: AdapterDiagnostic,
        connection: ConnectionDiagnostic,
        renderer: RendererDiagnostic,
        mcpGrants: [MCPGrantDiagnostic],
        safeExportFields: [DiagnosticsExportField],
        exportFileName: String,
        exportEnabled: Bool
    ) -> DiagnosticsViewState {
        DiagnosticsViewState(
            presentation: presentation,
            subject: subject,
            protocolCounters: protocolCounters,
            ignoredReasons: ignoredReasons,
            rejectedReasons: rejectedReasons,
            lease: lease,
            adapter: adapter,
            connection: connection,
            renderer: renderer,
            mcpGrants: mcpGrants,
            safeExportFields: safeExportFields,
            exportFileName: exportFileName,
            exportEnabled: exportEnabled
        )
    }

    public static func commandPalette(
        query: String,
        rooms: [Room],
        hosts: [HostConfiguration],
        canSplit: Bool,
        canClose: Bool
    ) -> CommandPaletteViewState {
        let groups = commandGroups(rooms: rooms, hosts: hosts, canSplit: canSplit, canClose: canClose)
        return CommandPaletteViewState(
            presentation: PresentationComposer.compose(.liveLocal),
            subject: PresentationSubject(componentName: "Command palette", target: "Allward commands"),
            query: query,
            groups: groups,
            selectedCommandID: groups.flatMap(\.commands).first(where: \.isEnabled)?.id
        )
    }

    private static func boardRow(
        _ row: BoardRow,
        room: Room?,
        now: Date,
        fallbackTint: TokenColor
    ) -> BoardViewState.Row {
        let publisher = row.publisher
        let permissionDecision = publisher.flatMap { publisher -> BoardViewState.PermissionDecision? in
            guard row.state == .needsInput || publisher.requestVerb != nil else { return nil }
            return BoardViewState.PermissionDecision(
                publisher: publisher.publisherName ?? publisher.publisherID.shortLabel,
                state: .ready,
                options: publisher.options.map {
                    PermissionOption(
                        id: $0.id,
                        verb: $0.label,
                        isLeastDestructive: $0.isLeastDestructive
                    )
                },
                expiryLabel: publisher.expiry.map { expiryLabel($0, now: now) }
            )
        }
        return BoardViewState.Row(
            id: row.id,
            roomName: room?.name ?? "Room \(row.roomID.shortLabel)",
            roomTint: room?.baseTint ?? fallbackTint,
            sessionTitle: row.title,
            host: row.host?.rawValue ?? "Local",
            workspace: row.workspace ?? "",
            presentation: PresentationComposer.compose(row.composition),
            composition: row.composition,
            subject: recordSubject(
                componentName: "Session",
                target: row.target,
                title: row.title,
                detail: row.disabledReason ?? row.detail,
                source: row.source,
                composition: row.composition,
                freshness: row.freshness,
                now: now,
                verb: publisher?.requestVerb,
                publisherName: publisher?.publisherName
            ),
            openLoopCount: row.openLoopCount,
            freshnessAge: row.freshness.age(at: now),
            freshnessBucket: row.freshness.bucket(at: now),
            destinationKey: row.destinationKey,
            provenanceLabel: sourceLabel(row.source),
            permissionDecision: permissionDecision,
            publisherDecisionActionable: row.approvalActionAvailable,
            locallyAcknowledgeable: row.publisher == nil && row.isActionable
        )
    }

    private static func boardState(_ state: BoardState) -> BoardViewState.ContentState {
        switch state {
        case .loading: .loading
        case .emptyNoSessions: .noSessions
        case .emptyNoOpenLoops: .noOpenLoops
        case .zeroPublishers: .zeroPublishers
        case .populated: .populated
        case .staleOrDegraded: .staleOrDegraded
        case .permission: .permission
        case .error: .error
        case .maximumContent: .maximumContent
        }
    }

    private static func boardFallbackPresentation(_ state: BoardState) -> ComposedPresentation {
        switch state {
        case .loading:
            PresentationComposer.compose(SourceComposition(connection: .connecting))
        case .emptyNoSessions, .emptyNoOpenLoops:
            PresentationComposer.compose(SourceComposition(freshness: .superseded))
        case .zeroPublishers, .populated, .maximumContent:
            PresentationComposer.compose(.liveLocal)
        case .staleOrDegraded:
            PresentationComposer.compose(SourceComposition(sourceHealth: .degraded))
        case .permission:
            PresentationComposer.compose(SourceComposition(permission: .active))
        case .error:
            PresentationComposer.compose(SourceComposition(sourceHealth: .error))
        }
    }

    private static func boardSubject(
        snapshot: BoardSnapshot,
        firstRow: BoardRow?,
        now: Date
    ) -> PresentationSubject {
        let reason: String? = switch snapshot.state {
        case .loading: nil
        case .emptyNoSessions: "No sessions"
        case .emptyNoOpenLoops: "No open loops"
        case .zeroPublishers: "No publisher records"
        case .populated:
            firstRow.flatMap { recordReason($0.composition, detail: $0.disabledReason ?? $0.detail) }
        case .staleOrDegraded: "One or more sources are stale or degraded"
        case .permission:
            firstRow.flatMap { recordReason($0.composition, detail: $0.disabledReason ?? $0.detail) }
        case .error:
            firstRow.flatMap { recordReason($0.composition, detail: $0.disabledReason ?? $0.detail) }
        case .maximumContent(let exactTotal): "Showing \(snapshot.visibleRowCount) of \(exactTotal) sessions"
        }
        return PresentationSubject(
            componentName: "Board",
            target: firstRow?.target.description ?? "Session inventory",
            reason: reason,
            capability: firstRow.map { sourceLabel($0.source) },
            verb: firstRow?.publisher?.requestVerb,
            source: firstRow.flatMap { $0.publisher?.publisherName } ?? firstRow.map { sourceLabel($0.source) },
            failedOperation: snapshot.state == .error ? "Load session inventory" : nil,
            recovery: snapshot.state == .error ? "Retry refresh" : nil,
            boundedStep: snapshot.state == .loading ? "Loading session inventory" : nil,
            freshnessBucket: firstRow?.freshness.label(at: now)
        )
    }

    private static func routerFallbackPresentation(_ state: RouterState) -> ComposedPresentation {
        switch state {
        case .loading:
            PresentationComposer.compose(SourceComposition(connection: .connecting))
        case .noActionableItems:
            PresentationComposer.compose(SourceComposition(freshness: .superseded))
        case .needsInput:
            PresentationComposer.compose(SourceComposition(permission: .active))
        case .error:
            PresentationComposer.compose(SourceComposition(sourceHealth: .error))
        case .staleOnly:
            PresentationComposer.compose(SourceComposition(freshness: .stale))
        case .focusFiltered:
            PresentationComposer.compose(SourceComposition(focus: .denied))
        case .degradedSource:
            PresentationComposer.compose(SourceComposition(sourceHealth: .degraded))
        case .active(let attentionClass):
            PresentationComposer.compose(composition(for: attentionClass))
        case .maximumContent:
            PresentationComposer.compose(.liveLocal)
        }
    }

    private static func composition(for attentionClass: AttentionClass) -> SourceComposition {
        switch attentionClass {
        case .needsInput: SourceComposition(permission: .active)
        case .error: SourceComposition(sourceHealth: .error)
        case .stale: SourceComposition(freshness: .stale)
        case .running: SourceComposition(work: .running)
        case .finished: SourceComposition(work: .finished, isFinishedTransitionEvent: true)
        }
    }

    private static func routerSubject(
        snapshot: RouterSnapshot,
        selectedItem: RouterItem?,
        now: Date
    ) -> PresentationSubject {
        let reason: String? = switch snapshot.state {
        case .loading: nil
        case .noActionableItems: "No actionable items"
        case .needsInput: selectedItem.flatMap { recordReason($0.composition, detail: nil) }
        case .error: selectedItem.flatMap { recordReason($0.composition, detail: nil) } ?? "Source error"
        case .staleOnly: "Only stale attention remains"
        case .focusFiltered: "Hidden by Focus"
        case .degradedSource(let source): "\(sourceLabel(source)) is degraded"
        case .active: selectedItem.flatMap { recordReason($0.composition, detail: nil) }
        case .maximumContent(let exactTotal): "Showing \(snapshot.items.count) of \(exactTotal) items"
        }
        return PresentationSubject(
            componentName: "Router",
            target: selectedItem?.target.description ?? "Attention queue",
            reason: reason,
            capability: selectedItem.map { sourceLabel($0.source) },
            source: selectedItem.map { sourceLabel($0.source) },
            failedOperation: snapshot.state == .error ? "Load attention queue" : nil,
            recovery: snapshot.state == .error ? "Retry refresh" : nil,
            boundedStep: snapshot.state == .loading ? "Loading attention queue" : nil,
            freshnessBucket: snapshot.freshness?.label(at: now)
        )
    }

    private static func routerZeroState(_ state: RouterState) -> RouterViewState.ZeroState {
        switch state {
        case .noActionableItems: .noActionableItems
        case .loading, .needsInput, .error, .staleOnly, .focusFiltered,
             .degradedSource, .active, .maximumContent: .none
        }
    }

    private static func routerIsFocusFiltered(_ state: RouterState) -> Bool {
        if case .focusFiltered = state { return true }
        return false
    }

    private static func digestState(_ state: DigestState, facts: [DigestFact]) -> DigestViewState.State {
        switch state {
        case .preparing:
            .preparing(step: "Preparing deterministic facts", cancellable: false)
        case .readyDeterministic:
            .readyDeterministic
        case .focusFiltered:
            .focusFiltered
        case .absent:
            .absent
        case .sourceStale:
            .sourceStale(reason: facts.compactMap(\.staleReason).first ?? "Source data is stale")
        case .partialSourceError(let sources):
            .partialSourceError(
                source: sources.map(sourceLabel).joined(separator: ", "),
                cause: facts.compactMap(\.staleReason).first ?? "Source read failed"
            )
        case .acknowledged:
            .acknowledged
        }
    }

    private static func digestFallbackPresentation(_ state: DigestState) -> ComposedPresentation {
        switch state {
        case .preparing:
            PresentationComposer.compose(SourceComposition(connection: .connecting))
        case .readyDeterministic:
            PresentationComposer.compose(.liveLocal)
        case .focusFiltered:
            PresentationComposer.compose(SourceComposition(focus: .denied))
        case .absent, .acknowledged:
            PresentationComposer.compose(SourceComposition(freshness: .superseded))
        case .sourceStale:
            PresentationComposer.compose(SourceComposition(freshness: .stale))
        case .partialSourceError:
            PresentationComposer.compose(SourceComposition(sourceHealth: .error))
        }
    }

    private static func digestSubject(
        snapshot: DigestSnapshot,
        firstFact: DigestFact?,
        now: Date
    ) -> PresentationSubject {
        let reason: String? = switch snapshot.state {
        case .preparing, .readyDeterministic: nil
        case .focusFiltered: "Hidden by Focus"
        case .absent: "No meaningful unseen changes"
        case .sourceStale: firstFact?.staleReason ?? "Source data is stale"
        case .partialSourceError(let sources):
            "Failed sources: \(sources.map(sourceLabel).joined(separator: ", "))"
        case .acknowledged: "Acknowledged"
        }
        return PresentationSubject(
            componentName: "Digest",
            target: firstFact?.sourceLink.target.description ?? "Re-entry digest",
            reason: reason,
            capability: firstFact.map { sourceLabel($0.sourceLink.source) },
            source: firstFact.map { sourceLabel($0.sourceLink.source) },
            failedOperation: ifPartialSourceError(snapshot.state, value: "Read digest sources"),
            recovery: ifPartialSourceError(snapshot.state, value: "Retry refresh"),
            boundedStep: snapshot.state == .preparing ? "Preparing deterministic facts" : nil,
            freshnessBucket: firstFact?.freshness.label(at: now)
        )
    }

    private static func recordSubject(
        componentName: String,
        target: Target,
        title: String,
        detail: String?,
        source: RecordSource,
        composition: SourceComposition,
        freshness: FreshnessStamp,
        now: Date,
        verb: String? = nil,
        publisherName: String? = nil
    ) -> PresentationSubject {
        let presentation = PresentationComposer.compose(composition)
        return PresentationSubject(
            componentName: componentName,
            target: target.description,
            reason: recordReason(composition, detail: detail),
            capability: sourceLabel(source),
            verb: verb,
            source: publisherName ?? sourceLabel(source),
            workKind: presentation.state == .running ? (detail ?? title) : nil,
            resultKind: presentation.state == .finished ? (detail ?? title) : nil,
            failedOperation: presentation.state == .error ? title : nil,
            recovery: presentation.state == .error ? detail : nil,
            boundedStep: presentation.state == .loading ? (detail ?? title) : nil,
            freshnessBucket: freshness.label(at: now)
        )
    }

    private static func recordReason(_ composition: SourceComposition, detail: String?) -> String? {
        if let detail, !detail.isEmpty { return detail }
        if composition.sourceHealth == .error { return "Source error" }
        if composition.sourceHealth == .degraded { return "Source degraded" }
        if composition.adapterOwnsTarget {
            switch composition.adapterHealth {
            case .degraded: return "Adapter degraded"
            case .denied: return "Adapter access denied"
            case .error: return "Adapter error"
            case .none, .available: break
            }
        }
        switch composition.connection {
        case .resolving: return "Resolving connection"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .degraded: return "Connection degraded"
        case .reconnecting: return "Reconnecting"
        case .closed(.explicit): return "Connection closed"
        case .closed(.trustDenied): return "Connection trust denied"
        case .closed(.nonretryable): return "Connection failed"
        case .idle, .ready: break
        }
        switch composition.publisherLifecycle {
        case .negotiating: return "Publisher negotiating"
        case .rejected: return "Publisher rejected"
        case .ended: return "Publisher ended"
        case .live: break
        }
        switch composition.permission {
        case .denied: return "Permission denied"
        case .expired: return "Permission expired"
        case .dismissed: return "Permission dismissed"
        case .none, .active, .granted: break
        }
        if composition.freshness == .stale { return "Source data is stale" }
        if composition.focus == .denied { return "Hidden by Focus" }
        if composition.control == .unavailable { return "Control unavailable" }
        return nil
    }

    private static func sourceLabel(_ source: RecordSource) -> String {
        switch source {
        case .publisherDirect: "Publisher"
        case .adapterAssociated: "Adapter"
        case .mcpAuthored: "MCP"
        case .shellIntegration: "Shell integration"
        case .terminalOSC133: "OSC 133"
        }
    }

    private static func expiryLabel(_ expiry: Date, now: Date) -> String {
        let remaining = max(0, expiry.timeIntervalSince(now))
        if remaining == 0 { return "Expired" }
        let bucket = FreshnessBucket.bucket(forAge: remaining)
        let duration = bucket.label(forAge: remaining).replacingOccurrences(of: " ago", with: "")
        return "Expires in \(duration)"
    }

    private static func generalSettings(
        _ configuration: Configuration,
        shellLane: String
    ) -> [GeneralSetting] {
        [
            GeneralSetting(
                id: "terminal.font-family", label: "Font", detail: nil,
                value: .choice(
                    selectedID: configuration.terminal.fontFamily,
                    choices: fontChoices(selected: configuration.terminal.fontFamily)),
                isEnabled: true),
            GeneralSetting(
                id: "terminal.font-size", label: "Terminal font size", detail: nil,
                value: .number(value: configuration.terminal.fontSize, range: 6...72, step: 1),
                isEnabled: true),

            GeneralSetting(
                id: "terminal.cursor-shape", label: "Cursor shape", detail: nil,
                value: .choice(
                    selectedID: configuration.terminal.cursorShape.rawValue,
                    choices: CursorShape.allCases.map {
                        SettingChoice(id: $0.rawValue, label: $0.rawValue.capitalized)
                    }
                ),
                isEnabled: true),
            GeneralSetting(
                id: "terminal.cursor-blink", label: "Cursor blink", detail: nil,
                value: .toggle(configuration.terminal.cursorBlink), isEnabled: true),
            GeneralSetting(
                id: "terminal.scrollback-capacity", label: "Scrollback lines", detail: nil,
                value: .number(
                    value: Double(configuration.terminal.scrollbackCapacity),
                    range: 1...10_000_000,
                    step: 1_000
                ),
                isEnabled: true),
            GeneralSetting(
                id: "shell.lane", label: "Shell integration lane", detail: nil,
                value: .text(shellLane), isEnabled: false),
        ]
    }

    /// Board density. It decides how much the Board shows, so it lives with the
    /// other things that decide how Allward looks.
    private static func appearanceSettings(_ configuration: Configuration) -> [GeneralSetting] {
        [
            GeneralSetting(
                id: "board.presentation", label: "Board presentation",
                detail: "How much detail the session Board packs into a row.",
                value: .choice(
                    selectedID: configuration.boardPresentation.rawValue,
                    choices: BoardPresentation.allCases.map {
                        SettingChoice(id: $0.rawValue, label: $0.rawValue.capitalized)
                    }
                ),
                isEnabled: true)
        ]
    }

    /// The master switch for earcons. Each Room chooses which ones it plays, so
    /// the switch that silences all of them belongs beside the Rooms.
    private static func soundSettings(_ configuration: Configuration) -> [GeneralSetting] {
        [
            GeneralSetting(
                id: "earcons.enabled", label: "Earcons",
                detail: "Off silences every Room's earcons without changing its rules.",
                value: .toggle(configuration.earconsEnabled), isEnabled: true)
        ]
    }

    private static func roomSetting(
        _ room: Room,
        themes: [SettingChoice],
        tintChoices: [RoomTintChoice]
    ) -> RoomSetting {
        let hostSummary: String
        let aliases = room.hostAliases.map(\.rawValue).sorted()
        if !aliases.isEmpty {
            hostSummary = aliases.joined(separator: ", ")
        } else if case .host(let alias) = room.defaults.destination {
            hostSummary = alias.rawValue
        } else {
            hostSummary = "Local"
        }
        return RoomSetting(
            id: room.id.rawValue.uuidString.lowercased(),
            name: room.name,
            hostSummary: hostSummary,
            sessionCount: room.sessionMappings.count,
            selectedTintID: room.baseTint.hexString,
            approvedTints: tintChoices,
            selectedThemeID: room.terminalThemeName,
            themeChoices: themes,
            notificationRules: Earcon.allCases.map {
                EarconSetting(
                    earcon: $0,
                    isEnabled: room.notificationRules.enabledEarcons.contains($0),
                    enabledByDefault: false
                )
            }
        )
    }

    private static func roomTintChoices(_ rooms: [Room]) -> [RoomTintChoice] {
        var seen: Set<String> = []
        return rooms.compactMap { room in
            let identifier = room.baseTint.hexString
            guard seen.insert(identifier).inserted else { return nil }
            return RoomTintChoice(id: identifier, label: room.name, tint: room.baseTint)
        }
    }

    private static func themeAppearance(_ name: String) -> Appearance {
        guard let theme = ThemeCatalog.theme(named: name) else { return .dark }
        return theme.background.relativeLuminance > 0.5 ? .light : .dark
    }

    private static func keySettings(_ dictationKey: String) -> [KeySetting] {
        [
            KeySetting(
                id: "session.new-local", action: "New local terminal", shortcut: Shortcut.newTab.display, isConfigurable: false),
            KeySetting(id: "window.new", action: "New window", shortcut: Shortcut.newWindow.display, isConfigurable: false),
            KeySetting(id: "pane.close", action: "Close pane", shortcut: Shortcut.closePane.display, isConfigurable: false),
            KeySetting(id: "pane.split-right", action: "Split right", shortcut: Shortcut.splitRight.display, isConfigurable: false),
            KeySetting(
                id: "pane.split-down", action: "Split down", shortcut: Shortcut.splitDown.display, isConfigurable: false),
            KeySetting(
                id: "pane.focus", action: "Focus pane", shortcut: Shortcut.focusPane, isConfigurable: false),
            KeySetting(
                id: "host.connect", action: "Connect to SSH host", shortcut: Shortcut.connectSSH.display, isConfigurable: false),
            KeySetting(
                id: "surface.board", action: "Board", shortcut: Shortcut.board.display, isConfigurable: false),
            KeySetting(
                id: "surface.router", action: "Router", shortcut: Shortcut.router.display, isConfigurable: false),
            KeySetting(
                id: "surface.digest", action: "Digest", shortcut: Shortcut.digest.display, isConfigurable: false),
            KeySetting(
                id: "surface.command-palette", action: "Command palette", shortcut: Shortcut.palette.display,
                isConfigurable: false),
            KeySetting(
                id: "room.switcher", action: "Room switcher", shortcut: Shortcut.rooms.display, isConfigurable: false),
            KeySetting(id: "teleport", action: "Teleport", shortcut: Shortcut.teleport.display, isConfigurable: false),
            KeySetting(id: "settings.open", action: "Settings", shortcut: Shortcut.settings.display, isConfigurable: false),
            KeySetting(
                id: "diagnostics.open", action: "Diagnostics", shortcut: KeyChord("/", [.command, .shift]).display, isConfigurable: false),
            KeySetting(
                id: "speech.dictation-key", action: "Hold to dictate", shortcut: dictationKey,
                isConfigurable: true),
        ]
    }

    private static func integrationSettings(
        configuration: Configuration,
        adapterHealth: AdapterHealth,
        mcpCommandLine: String
    ) -> [IntegrationSetting] {
        let adapterComposition = adapterHealth == .none
            ? SourceComposition(freshness: .superseded)
            : SourceComposition(adapterHealth: adapterHealth, adapterOwnsTarget: true)
        let mcpComposition = configuration.mcpEnabled
            ? SourceComposition.liveLocal
            : SourceComposition(freshness: .superseded)
        return [
            IntegrationSetting(
                id: "herdr",
                name: "herdr",
                detail: "\(adapterHealthLabel(adapterHealth)). Discovers panes from a "
                    + "running herdr server; there is nothing to switch on here, it "
                    + "appears when a server does.",
                commandLine: nil,
                presentation: PresentationComposer.compose(adapterComposition),
                subject: PresentationSubject(
                    componentName: "Integration",
                    target: "herdr adapter",
                    reason: recordReason(adapterComposition, detail: nil),
                    capability: "Workspace routing"
                ),
                isEnabled: adapterHealth != .none,
                isSwitchable: false
            ),
            IntegrationSetting(
                id: "mcp",
                name: "MCP",
                detail: configuration.mcpEnabled
                    ? "On. Agents and the allward-mcp client can read this "
                        + "terminal and drive it."
                    : "Off. Nothing outside Allward can read or drive this terminal.",
                commandLine: mcpCommandLine,
                presentation: PresentationComposer.compose(mcpComposition),
                subject: PresentationSubject(componentName: "Integration", target: "Allward MCP"),
                isEnabled: configuration.mcpEnabled
            ),
        ]
    }

    /// The installed monospaced families, with whatever is configured kept in
    /// the list even if it is missing, so the control never shows blank.
    private static func fontChoices(selected: String) -> [SettingChoice] {
        var families = InstalledFonts.monospacedFamilies()
        if !families.contains(selected) { families.insert(selected, at: 0) }
        return families.map { SettingChoice(id: $0, label: $0) }
    }

    private static func adapterHealthLabel(_ health: AdapterHealth) -> String {
        switch health {
        case .none: "Not in use"
        case .available: "Available"
        case .degraded: "Degraded"
        case .denied: "Access denied"
        case .error: "Unavailable"
        }
    }

    private static let privacySettings = [
        PrivacySetting(
            id: "intelligence",
            label: "Intelligence",
            value: .onDevice,
            detail: "Deterministic facts remain available without rewriting."
        ),
        PrivacySetting(
            id: "crash-reports",
            label: "Crash reports",
            value: .permissionRequired,
            detail: "Review each report before sharing."
        ),
        PrivacySetting(
            id: "speech-retention",
            label: "Speech retention",
            value: .disabled,
            detail: "Dictation is transcribed on device and the audio is discarded "
                + "immediately. There is no setting to retain it."
        ),
    ]

    private static func commandGroups(
        rooms: [Room],
        hosts: [HostConfiguration],
        canSplit: Bool,
        canClose: Bool
    ) -> [CommandGroup] {
        let roomNames = rooms.map(\.name).joined(separator: ", ")
        let hostAliases = hosts.map { $0.alias.rawValue }.joined(separator: ", ")
        return [
            CommandGroup(id: "panes", title: "Panes", commands: [
                paletteCommand("session.new-local", "New local terminal", nil, Shortcut.newTab.display),
                paletteCommand("window.new", "New window", nil, Shortcut.newWindow.display),
                paletteCommand("pane.close", "Close pane", nil, Shortcut.closePane.display, enabled: canClose),
                paletteCommand("pane.split-right", "Split right", nil, Shortcut.splitRight.display, enabled: canSplit),
                paletteCommand("pane.split-down", "Split down", nil, Shortcut.splitDown.display, enabled: canSplit),
                paletteCommand("pane.focus", "Focus pane", nil, Shortcut.focusPane),
            ]),
            CommandGroup(id: "connections", title: "Connections", commands: [
                paletteCommand(
                    "host.connect",
                    "Connect to SSH host",
                    hostAliases.isEmpty ? "No hosts configured" : hostAliases,
                    Shortcut.connectSSH.display,
                    enabled: !hosts.isEmpty
                ),
            ]),
            CommandGroup(id: "surfaces", title: "Surfaces", commands: [
                paletteCommand("surface.board", "Board", nil, Shortcut.board.display),
                paletteCommand("surface.router", "Router", nil, Shortcut.router.display),
                paletteCommand("surface.digest", "Digest", nil, Shortcut.digest.display),
                paletteCommand("surface.command-palette", "Command palette", nil, Shortcut.palette.display),
            ]),
            CommandGroup(id: "navigation", title: "Navigation", commands: [
                paletteCommand(
                    "room.switcher",
                    "Room switcher",
                    roomNames.isEmpty ? "No Rooms configured" : roomNames,
                    Shortcut.rooms.display,
                    enabled: !rooms.isEmpty
                ),
                paletteCommand("teleport", "Teleport", nil, Shortcut.teleport.display),
            ]),
            CommandGroup(id: "application", title: "Application", commands: [
                paletteCommand("settings.open", "Settings", nil, Shortcut.settings.display),
                paletteCommand("diagnostics.open", "Diagnostics", nil, KeyChord("/", [.command, .shift]).display),
            ]),
        ]
    }

    private static func paletteCommand(
        _ id: String,
        _ title: String,
        _ subtitle: String?,
        _ shortcut: String,
        enabled: Bool = true
    ) -> PaletteCommand {
        PaletteCommand(id: id, title: title, subtitle: subtitle, shortcut: shortcut, isEnabled: enabled)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func indexRooms(_ rooms: [Room]) -> [RoomID: Room] {
        Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func ifPartialSourceError(_ state: DigestState, value: String) -> String? {
        if case .partialSourceError = state { return value }
        return nil
    }
}
