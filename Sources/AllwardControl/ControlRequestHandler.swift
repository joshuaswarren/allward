import AllwardCore
import AllwardMultiplexer
import AllwardSurfaces

extension ControlService: ControlRequestHandling {
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case let .createLocalPane(target, generation, paneRequest, key):
            .mutation(
                await createLocalPane(
                    target: target,
                    generation: generation,
                    request: paneRequest,
                    idempotencyKey: key
                )
            )
        case let .createSSHPane(target, generation, paneRequest, host, command, key):
            .mutation(
                await createSSHPane(
                    target: target,
                    generation: generation,
                    request: paneRequest,
                    host: host,
                    command: command,
                    idempotencyKey: key
                )
            )
        case let .attachAdapterPane(target, generation, window, tab, geometry, session, key):
            .mutation(
                await attachAdapterPane(
                    target: target,
                    generation: generation,
                    request: AdapterPaneRequest(
                        window: window,
                        tab: tab,
                        geometry: geometry,
                        session: session.adapterSession
                    ),
                    idempotencyKey: key
                )
            )
        case let .closePane(target, generation, key):
            .mutation(await closePane(target: target, generation: generation, idempotencyKey: key))
        case let .splitPane(target, generation, destination, orientation, ratio, geometry, key):
            .mutation(
                await splitPane(
                    target: target,
                    generation: generation,
                    destination: destination,
                    orientation: orientation,
                    ratio: ratio,
                    geometry: geometry,
                    idempotencyKey: key
                )
            )
        case let .focusPane(target, generation, key):
            .mutation(await focusPane(target: target, generation: generation, idempotencyKey: key))
        case let .movePaneFocus(target, generation, direction, key):
            .mutation(
                await movePaneFocus(
                    target: target,
                    generation: generation,
                    direction: direction,
                    idempotencyKey: key
                )
            )
        case let .resizePane(target, generation, columns, rows, key):
            .mutation(
                await resizePane(
                    target: target,
                    generation: generation,
                    columns: columns,
                    rows: rows,
                    idempotencyKey: key
                )
            )
        case let .sendText(target, generation, text, source, key):
            .mutation(
                await sendText(
                    to: target,
                    generation: generation,
                    text: text,
                    source: source,
                    idempotencyKey: key
                )
            )
        case let .sendKeys(target, generation, keys, source, key):
            .mutation(
                await sendKeys(
                    to: target,
                    generation: generation,
                    keys: keys.map(\.terminalKey),
                    source: source,
                    idempotencyKey: key
                )
            )
        case let .lockInputRoute(pane):
            .inputRoute(await encodedRouteLock(for: pane))
        case let .isRouteCurrent(pane, handle, routeGeneration, ownershipGeneration):
            .boolean(
                await isRouteCurrent(
                    pane: pane,
                    handle: handle,
                    routeGeneration: routeGeneration,
                    ownershipGeneration: ownershipGeneration
                )
            )
        case let .injectText(text, pane, handle, routeGeneration, ownershipGeneration):
            .boolean(
                await injectText(
                    text,
                    pane: pane,
                    handle: handle,
                    routeGeneration: routeGeneration,
                    ownershipGeneration: ownershipGeneration
                )
            )
        case let .readScreen(pane):
            .screen(await readScreen(pane: pane))
        case let .readHistory(pane, lines):
            .history(await readHistory(pane: pane, lines: lines))
        case let .lastCommand(pane):
            .command(await lastCommand(pane: pane))
        case let .exitCode(pane):
            .exitCode(await exitCode(pane: pane))
        case let .readScreenTarget(target):
            .screen(await readScreen(target: target))
        case let .readHistoryTarget(target, lines):
            .history(await readHistory(target: target, lines: lines))
        case let .lastCommandTarget(target):
            .command(await lastCommand(target: target))
        case let .exitCodeTarget(target):
            .exitCode(await exitCode(target: target))
        case .listPanes:
            .topology(await listPanes())
        case let .createTab(target, generation, window, tab, key):
            .mutation(
                await createTab(
                    target: target,
                    generation: generation,
                    window: window,
                    tab: tab,
                    idempotencyKey: key
                )
            )
        case let .closeTab(target, generation, window, tab, key):
            .mutation(
                await closeTab(
                    target: target,
                    generation: generation,
                    window: window,
                    tab: tab,
                    idempotencyKey: key
                )
            )
        case let .setRoom(window, room, target, generation, key):
            .mutation(
                await setRoom(
                    window: window,
                    room: room,
                    target: target,
                    generation: generation,
                    idempotencyKey: key
                )
            )
        case let .teleport(target, generation, destination, key):
            .mutation(
                await teleport(
                    target: target,
                    generation: generation,
                    to: destination.destination,
                    idempotencyKey: key
                )
            )
        case let .runCommand(target, generation, command, bound, key):
            .runCommand(
                await runCommand(
                    target: target,
                    generation: generation,
                    command: command,
                    bound: bound,
                    idempotencyKey: key
                )
            )
        case let .recoverCommandReceipt(key):
            .commandReceipt(recoverCommandReceipt(key))
        case .boardSnapshot:
            .board(await boardSnapshot())
        case .routerSnapshot:
            .router(await routerSnapshot())
        case .listRooms:
            .rooms(await listRooms())
        case let .createAuthoredRecord(target, generation, logicalKey, content, authority, invocationID, key):
            .authored(
                await createAuthoredRecord(
                    target: target,
                    generation: generation,
                    callerLogicalKey: logicalKey,
                    content: content.authoredContent,
                    authority: authority.authoredAuthority,
                    invocationID: invocationID,
                    idempotencyKey: key
                )
            )
        case let .updateAuthoredRecord(
            target,
            generation,
            logicalKey,
            content,
            authority,
            invocationID,
            revision,
            key
        ):
            .authored(
                await updateAuthoredRecord(
                    target: target,
                    generation: generation,
                    callerLogicalKey: logicalKey,
                    content: content.authoredContent,
                    authority: authority.authoredAuthority,
                    invocationID: invocationID,
                    expectedRevision: revision,
                    idempotencyKey: key
                )
            )
        case let .endAuthoredRecord(
            target,
            generation,
            logicalKey,
            authority,
            invocationID,
            revision,
            reason,
            key
        ):
            .authored(
                await endAuthoredRecord(
                    target: target,
                    generation: generation,
                    callerLogicalKey: logicalKey,
                    authority: authority.authoredAuthority,
                    invocationID: invocationID,
                    expectedRevision: revision,
                    reason: reason,
                    idempotencyKey: key
                )
            )
        case let .staleMCPAuthority(namespace):
            await acknowledgeStaleMCPAuthority(namespace)
        }
    }

    private func acknowledgeStaleMCPAuthority(_ namespace: String) async -> ControlResponse {
        await staleMCPAuthority(namespace: namespace)
        return .acknowledged
    }

    private func encodedRouteLock(for pane: PaneID) async -> ControlInputRouteLock? {
        guard let route = await lockInputRoute(for: pane) else { return nil }
        return ControlInputRouteLock(
            handle: route.handle,
            routeGeneration: route.routeGeneration,
            ownershipGeneration: route.ownershipGeneration
        )
    }
}
