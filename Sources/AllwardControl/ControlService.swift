import AllwardCore
import AllwardMultiplexer
import AllwardRemote
import AllwardRooms
import AllwardSurfaces
import AllwardTerminal
import Foundation

struct InputRouteState: Sendable {
    var handle: UUID
    var routeGeneration: Generation
    var ownershipGeneration: Generation
}

public actor ControlService {
    let registry = PaneRegistry()
    let arbiter = PaneInputArbiter()
    let ledger: MutationLedger
    let transports: [any RemoteTransport]
    let adapter: any MultiplexerAdapter
    let clock: any AllwardClock
    let roomStore: RoomStore
    let surfaceStore: SurfaceStore
    let connectionBound: AttemptBound
    /// What a program is allowed to do to the machine, from configuration.
    /// Both default off; see `TerminalConfiguration`.
    var terminalPolicy = TerminalPolicy()
    var inputRoutes: [PaneID: InputRouteState] = [:]
    var inputOwnership: [PaneID: Generation] = [:]
    var commandReceipts: [IdempotencyKey: CommandExecutionReceipt] = [:]
    var commandReceiptOrder: [IdempotencyKey] = []

    public func setTerminalPolicy(_ policy: TerminalPolicy) {
        terminalPolicy = policy
    }

    /// Publishes the theme's colours to every engine so `OSC 10/11/12` queries
    /// are answered with what is actually on screen.
    public func setReportedColors(
        foreground: DynamicColors.RGB, background: DynamicColors.RGB, cursor: DynamicColors.RGB
    ) async {
        for session in await registry.allSessions {
            await session.setReportedColors(
                foreground: foreground, background: background, cursor: cursor)
        }
    }

    public init(
        transports: [any RemoteTransport],
        adapter: any MultiplexerAdapter = NoMultiplexerAdapter(),
        clock: any AllwardClock = SystemClock(),
        roomStore: RoomStore,
        surfaceStore: SurfaceStore,
        ledger: MutationLedger = MutationLedger(),
        connectionBound: AttemptBound = .connect
    ) {
        self.transports = transports
        self.adapter = adapter
        self.clock = clock
        self.roomStore = roomStore
        self.surfaceStore = surfaceStore
        self.ledger = ledger
        self.connectionBound = connectionBound
    }

    public func createLocalPane(
        target: Target,
        generation: Generation,
        request: PaneCreationRequest,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recorded(idempotencyKey) {
            await self.createPane(
                kind: .createLocalPane,
                requestedTarget: target,
                generation: generation,
                request: request,
                destination: .localShell(
                    workingDirectory: request.workingDirectory,
                    environment: request.environment
                ),
                contentRoute: nil
            )
        }
    }

    public func createSSHPane(
        target: Target,
        generation: Generation,
        request: PaneCreationRequest,
        host: HostAlias,
        command: [String]? = nil,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recorded(idempotencyKey) {
            await self.createPane(
                kind: .createSSHPane,
                requestedTarget: target,
                generation: generation,
                request: request,
                destination: .ssh(host, command: command, environment: request.environment),
                contentRoute: nil
            )
        }
    }

    public func attachAdapterPane(
        target: Target,
        generation: Generation,
        request: AdapterPaneRequest,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recorded(idempotencyKey) {
            if let rejection = await self.registry.rejection(
                for: target,
                expectedGeneration: generation
            ) {
                return .rejected(rejection)
            }
            let route = await self.adapter.route(for: request.session)
            guard route.isLive else {
                return .rejected(.unsupported("Read-only adapter routes cannot own an interactive session"))
            }
            let command = self.adapter.attachCommand(for: request.session, route: route)
            guard !command.isEmpty else {
                return .rejected(.unsupported("The adapter did not provide an attach command"))
            }
            let destination = RemoteDestination.ssh(
                request.session.host,
                command: command
            )
            let creation = PaneCreationRequest(
                window: request.window,
                tab: request.tab,
                geometry: request.geometry,
                workingDirectory: request.session.workingDirectory
            )
            return await self.createPane(
                kind: .attachAdapterPane,
                requestedTarget: target,
                generation: generation,
                request: creation,
                destination: destination,
                contentRoute: route
            )
        }
    }

    public func splitPane(
        target: Target,
        generation: Generation,
        destination: RemoteDestination,
        orientation: SplitOrientation,
        ratio: Double = 0.5,
        geometry: TerminalGeometry = .standard,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recorded(idempotencyKey) {
            guard let existingPane = target.pane else {
                return .rejected(.targetMismatch(expected: target, actual: target))
            }
            if let rejection = await self.registry.rejection(
                for: target,
                expectedGeneration: generation
            ) {
                return .rejected(rejection)
            }
            let opened = await self.openSession(destination: destination, geometry: geometry)
            guard case let .success(session) = opened else {
                if case let .failure(rejection) = opened { return .rejected(rejection) }
                return .rejected(.unsupported("Session could not be opened"))
            }
            let paneID = PaneID()
            let createdTarget = Target(room: target.room, session: session.id, pane: paneID)
            let inserted = await self.registry.splitPane(
                existingPane: existingPane,
                newPane: paneID,
                session: session,
                target: createdTarget,
                destination: destination,
                contentRoute: nil,
                orientation: orientation,
                ratio: ratio,
                expectedGeneration: generation
            )
            switch inserted {
            case let .success(change):
                await session.start()
                return .applied(
                    await self.receipt(
                        kind: .splitPane,
                        target: createdTarget,
                        change: change,
                        pane: paneID
                    )
                )
            case let .failure(rejection):
                await session.close()
                return .rejected(rejection)
            }
        }
    }

    private func createPane(
        kind: ControlMutationKind,
        requestedTarget: Target,
        generation: Generation,
        request: PaneCreationRequest,
        destination: RemoteDestination,
        contentRoute: AdapterContentRoute?
    ) async -> ControlMutationResult {
        if let rejection = await registry.rejection(
            for: requestedTarget,
            expectedGeneration: generation
        ) {
            return .rejected(rejection)
        }
        let opened = await openSession(destination: destination, geometry: request.geometry)
        guard case let .success(session) = opened else {
            if case let .failure(rejection) = opened { return .rejected(rejection) }
            return .rejected(.unsupported("Session could not be opened"))
        }
        let paneID = PaneID()
        let actualTarget = Target(room: requestedTarget.room, session: session.id, pane: paneID)
        let inserted = await registry.insertFirstPane(
            paneID,
            session: session,
            target: actualTarget,
            destination: destination,
            contentRoute: contentRoute,
            window: request.window,
            tab: request.tab,
            expectedGeneration: generation
        )
        switch inserted {
        case let .success(change):
            await session.start()
            return .applied(
                receipt(
                    kind: kind,
                    target: actualTarget,
                    change: change,
                    window: request.window,
                    tab: request.tab,
                    pane: paneID
                )
            )
        case let .failure(rejection):
            await session.close()
            return .rejected(rejection)
        }
    }

    private func openSession(
        destination: RemoteDestination,
        geometry: TerminalGeometry
    ) async -> Result<Session, ControlRejection> {
        guard let transport = transports.first(where: { $0.supports(destination) }) else {
            return .failure(.unsupported("No transport supports this destination"))
        }
        do {
            let channel = try await transport.open(
                destination,
                geometry: (geometry.columns, geometry.rows),
                bound: connectionBound
            )
            return .success(
                Session(
                    channel: channel,
                    geometry: geometry,
                    clock: clock,
                    allowLogFile: terminalPolicy.allowLogFile,
                    allowClipboardRead: terminalPolicy.allowClipboardRead
                )
            )
        } catch let error as AllwardError {
            return .failure(.failed(error))
        } catch {
            return .failure(
                .failed(
                    AllwardError(
                        domain: .transport,
                        operation: "open",
                        cause: String(describing: error),
                        recovery: "Retry or inspect the transport configuration."
                    )
                )
            )
        }
    }

    func receipt(
        kind: ControlMutationKind,
        target: Target,
        change: RegistryChange,
        window: WindowID? = nil,
        tab: TabID? = nil,
        pane: PaneID? = nil
    ) -> ControlMutationReceipt {
        ControlMutationReceipt(
            kind: kind,
            target: target,
            generationBefore: change.before,
            generationAfter: change.after,
            window: window,
            tab: tab,
            pane: pane
        )
    }

    private func recorded(
        _ key: IdempotencyKey,
        operation: @escaping @Sendable () async -> ControlMutationResult
    ) async -> ControlMutationResult {
        do { return try await ledger.perform(key: key, operation: operation) } catch {
            return .rejected(
                .failed(
                    AllwardError(
                        domain: .control,
                        operation: "idempotency",
                        cause: String(describing: error),
                        recovery: "Use a new idempotency key."
                    )
                )
            )
        }
    }
}
