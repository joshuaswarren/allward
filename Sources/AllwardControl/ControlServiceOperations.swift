import AllwardCore
import AllwardRooms
import AllwardTerminal
import Foundation

extension ControlService {
    public func closePane(
        target: Target,
        generation: Generation,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            guard let paneID = target.pane else { return .rejected(.targetMismatch(expected: target, actual: target)) }
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            switch await self.registry.closePane(paneID, expectedGeneration: generation) {
            case let .success(removed):
                await removed.session.close()
                await self.arbiter.cancelQueuedInput(for: paneID)
                await self.invalidateInputRoute(for: paneID)
                return .applied(
                    await self.receipt(kind: .closePane, target: target, change: removed.change, pane: paneID)
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func focusPane(
        target: Target,
        generation: Generation,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            guard let paneID = target.pane else { return .rejected(.targetMismatch(expected: target, actual: target)) }
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            switch await self.registry.focusPane(paneID, expectedGeneration: generation) {
            case let .success(change):
                return .applied(
                    await self.receipt(kind: .focusPane, target: target, change: change, pane: paneID)
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func movePaneFocus(
        target: Target,
        generation: Generation,
        direction: FocusDirection,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            guard let paneID = target.pane else { return .rejected(.targetMismatch(expected: target, actual: target)) }
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            switch await self.registry.moveFocus(
                from: paneID,
                direction: direction,
                expectedGeneration: generation
            ) {
            case let .success((focusedPane, change)):
                guard let focusedTarget = await self.registry.target(for: focusedPane) else {
                    return .rejected(.paneNotFound(focusedPane))
                }
                return .applied(
                    await self.receipt(
                        kind: .movePaneFocus,
                        target: focusedTarget,
                        change: change,
                        pane: focusedPane
                    )
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func resizePane(
        target: Target,
        generation: Generation,
        columns: Int,
        rows: Int,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            guard let paneID = target.pane else { return .rejected(.targetMismatch(expected: target, actual: target)) }
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            guard let session = await self.registry.session(for: paneID) else {
                return .rejected(.paneNotFound(paneID))
            }
            await session.resize(columns: columns, rows: rows)
            return .applied(
                await self.receipt(
                    kind: .resizePane,
                    target: target,
                    change: RegistryChange(before: generation, after: generation),
                    pane: paneID
                )
            )
        }
    }

    public func sendText(
        to target: Target,
        generation: Generation,
        text: String,
        source: PaneInputSource = .mcp,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            await self.deliverInput(
                kind: .sendText,
                target: target,
                generation: generation,
                source: source
            ) { session in
                await session.paste(text)
            }
        }
    }

    public func sendKeys(
        to target: Target,
        generation: Generation,
        keys: [AllwardTerminal.TerminalKey],
        source: PaneInputSource = .mcp,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            await self.deliverInput(
                kind: .sendKeys,
                target: target,
                generation: generation,
                source: source
            ) { session in
                let bytes = await session.encoded(keys)
                return await session.write(bytes)
            }
        }
    }

    public func readScreen(pane: PaneID) async -> ScreenRead? {
        guard let session = await registry.session(for: pane) else { return nil }
        let snapshot = await session.snapshot()
        return ScreenRead(
            pane: pane,
            generation: snapshot.generation,
            lines: snapshot.rows.indices.map(snapshot.plainText(row:)),
            cursor: snapshot.cursor,
            title: snapshot.title
        )
    }

    public func readHistory(pane: PaneID, lines: Int) async -> [String]? {
        guard let session = await registry.session(for: pane) else { return nil }
        return await session.history(lines: lines)
    }

    public func lastCommand(pane: PaneID) async -> CommandRegion? {
        guard let session = await registry.session(for: pane) else { return nil }
        return await session.commandRegions().last
    }

    public func exitCode(pane: PaneID) async -> Int32? {
        await lastCommand(pane: pane)?.exitCode
    }

    public func listPanes() async -> TopologySnapshot {
        await registry.snapshot()
    }

    public func createTab(
        target: Target,
        generation: Generation,
        window: WindowID,
        tab: TabID = TabID(),
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            switch await self.registry.createTab(
                window: window,
                tab: tab,
                room: target.room,
                expectedGeneration: generation
            ) {
            case let .success(change):
                return .applied(
                    await self.receipt(
                        kind: .createTab,
                        target: target,
                        change: change,
                        window: window,
                        tab: tab
                    )
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func closeTab(
        target: Target,
        generation: Generation,
        window: WindowID,
        tab: TabID,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            switch await self.registry.closeTab(
                tab,
                window: window,
                target: target,
                expectedGeneration: generation
            ) {
            case let .success(removed):
                for session in removed.sessions { await session.close() }
                for paneID in removed.paneIDs {
                    await self.arbiter.cancelQueuedInput(for: paneID)
                    await self.invalidateInputRoute(for: paneID)
                }
                return .applied(
                    await self.receipt(
                        kind: .closeTab,
                        target: target,
                        change: removed.change,
                        window: window,
                        tab: tab
                    )
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func setRoom(
        window: WindowID,
        room: RoomID,
        target: Target,
        generation: Generation,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            guard await self.roomStore.room(id: room) != nil else {
                return .rejected(.unsupported("Room is not configured"))
            }
            switch await self.registry.setRoom(
                window: window,
                room: room,
                target: target,
                expectedGeneration: generation
            ) {
            case let .success(change):
                do { try await self.roomStore.setActiveRoom(room, for: window) } catch {
                    return .rejected(await self.controlFailure(operation: "set-room", error: error))
                }
                let actualTarget = Target(room: room, session: target.session, pane: target.pane)
                return .applied(
                    await self.receipt(
                        kind: .setRoom,
                        target: actualTarget,
                        change: change,
                        window: window
                    )
                )
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func teleport(
        target: Target,
        generation: Generation,
        to destination: TeleportDestination,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            if let paneID = destination.pane {
                guard let paneTarget = await self.registry.target(for: paneID) else {
                    return .rejected(.paneNotFound(paneID))
                }
                guard paneTarget.room == target.room else {
                    return .rejected(.targetMismatch(expected: paneTarget, actual: target))
                }
                switch await self.registry.focusPane(paneID, expectedGeneration: generation) {
                case let .success(change):
                    return .applied(
                        await self.receipt(
                            kind: .teleport,
                            target: paneTarget,
                            change: change,
                            pane: paneID
                        )
                    )
                case let .failure(rejection): return .rejected(rejection)
                }
            }
            guard let adapterSession = destination.adapterSession else {
                return .rejected(.unsupported("Teleport destination is empty"))
            }
            if let rejection = await self.registry.rejection(for: target, expectedGeneration: generation) {
                return .rejected(rejection)
            }
            do {
                try await self.adapter.focus(session: adapterSession, bound: .controlRequest)
            } catch {
                return .rejected(await self.controlFailure(operation: "teleport", error: error))
            }
            switch await self.registry.touch(expectedGeneration: generation) {
            case let .success(change):
                return .applied(await self.receipt(kind: .teleport, target: target, change: change))
            case let .failure(rejection): return .rejected(rejection)
            }
        }
    }

    public func listRooms() async -> [Room] {
        await roomStore.rooms()
    }

    public func recoverMutation(_ key: IdempotencyKey) async -> ControlMutationResult? {
        try? await ledger.lookup(key, as: ControlMutationResult.self)
    }

    func deliverInput(
        kind: ControlMutationKind,
        target: Target,
        generation: Generation,
        source: PaneInputSource,
        delivery: @escaping @Sendable (Session) async -> Bool
    ) async -> ControlMutationResult {
        guard let paneID = target.pane else { return .rejected(.targetMismatch(expected: target, actual: target)) }
        if let rejection = await registry.rejection(for: target, expectedGeneration: generation) {
            return .rejected(rejection)
        }
        guard let session = await registry.session(for: paneID) else {
            return .rejected(.paneNotFound(paneID))
        }
        let result = await arbiter.submit(
            pane: paneID,
            target: target,
            expectedGeneration: generation,
            source: source,
            currentGeneration: {
                guard await session.isOpen() else { return nil }
                return await self.registry.generation
            },
            deliver: { await delivery(session) }
        )
        switch result {
        case .delivered:
            return .applied(
                receipt(
                    kind: kind,
                    target: target,
                    change: RegistryChange(before: generation, after: generation),
                    pane: paneID
                )
            )
        case let .dropped(reason):
            return .rejected(.inputDropped(String(describing: reason)))
        }
    }

    func recordedMutation(
        _ key: IdempotencyKey,
        operation: @escaping @Sendable () async -> ControlMutationResult
    ) async -> ControlMutationResult {
        do { return try await ledger.perform(key: key, operation: operation) } catch {
            return .rejected(controlFailure(operation: "idempotency", error: error))
        }
    }

    func controlFailure(operation: String, error: Error) -> ControlRejection {
        if let error = error as? AllwardError { return .failed(error) }
        return .failed(
            AllwardError(
                domain: .control,
                operation: operation,
                cause: String(describing: error),
                recovery: "Retry or inspect control diagnostics."
            )
        )
    }
}
