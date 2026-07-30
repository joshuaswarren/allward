import AllwardCore
import AllwardMultiplexer
import Foundation

// LIMITATION: herdr 0.7.5 exposes no structured todo resource or todo event.
// LIMITATION: protocol 17 does not verify generic pane output subscriptions, so output events never trigger reads.

public actor HerdrAdapter: MultiplexerAdapter {
    public nonisolated let displayName = "herdr"
    public nonisolated let capabilities = AdapterCapabilities(
        discoversSessions: true,
        durableWorkspaceIdentity: true,
        teleport: true,
        focusSynchronization: true,
        coarseAgentState: true
    )
    public nonisolated let events: AsyncStream<AdapterEvent>
    public nonisolated let endpoint: HerdrEndpoint

    private let continuation: AsyncStream<AdapterEvent>.Continuation
    private let client: HerdrSocketClient
    private let mapper: HerdrSessionMapper
    private let selector: HerdrRouteSelector
    private let clock: any AllwardClock

    private var currentHealth: AdapterHealth = .none
    private var currentSessions: [AdapterSession] = []
    private var agentSessionIDs: Set<String> = []
    private var availability: HerdrRouteAvailability
    private var selections: [String: HerdrRouteSelection] = [:]
    private var failedRoutes: [String: Set<AdapterContentRoute>] = [:]
    private var retainedSnapshots: [String: HerdrPaneSnapshotObservation] = [:]
    private var paneRevisions: [String: UInt64] = [:]
    private var eventTask: Task<Void, Never>?
    private var started = false

    public init(
        client: HerdrSocketClient,
        availability: HerdrRouteAvailability = HerdrRouteAvailability(),
        clock: any AllwardClock = SystemClock()
    ) {
        let pair = AsyncStream<AdapterEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.events = pair.stream
        self.continuation = pair.continuation
        self.endpoint = client.endpoint
        self.client = client
        var effectiveAvailability = availability
        effectiveAvailability.snapshotReadAvailable =
            availability.snapshotReadAvailable && client.supportsPaneRead
        self.availability = effectiveAvailability
        self.clock = clock
        self.mapper = HerdrSessionMapper(clock: clock)
        self.selector = HerdrRouteSelector()
    }

    public var health: AdapterHealth { currentHealth }

    public func start() async {
        guard !started else { return }
        started = true
        _ = try? await refresh(trigger: .initialOpen, bound: .controlRequest)

        guard client.hasEventSource else { return }
        let frames = client.eventFrames()
        eventTask = Task { [client] in
            for await frame in frames {
                if Task.isCancelled { break }
                do {
                    let event = try client.decodeEvent(frame)
                    await self.consume(event)
                } catch {
                    self.publishFailure(error, operation: "event decode")
                }
            }
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        started = false
        currentHealth = .none
        continuation.yield(.health(.none))
    }

    public func listSessions(bound: AttemptBound) async throws -> [AdapterSession] {
        try await refresh(trigger: .manualRefresh, bound: bound)
    }

    public func refresh(
        trigger: HerdrSnapshotTrigger,
        bound: AttemptBound
    ) async throws -> [AdapterSession] {
        do {
            let snapshot = try await client.snapshot(trigger: trigger, bound: bound)
            try acceptRevisions(from: snapshot)
            let mapped = mapper.map(snapshot: snapshot, host: endpoint.host)
            currentSessions = mapped.sessions
            agentSessionIDs = mapped.agentSessionIDs
            availability.socketAvailable = true
            availability.snapshotReadAvailable = client.supportsPaneRead
            currentHealth = .available
            continuation.yield(.health(.available))
            continuation.yield(.sessions(currentSessions))
            return currentSessions
        } catch {
            availability.socketAvailable = false
            let wrapped = makeError(error, operation: "session.snapshot")
            currentHealth = currentSessions.isEmpty ? .error : .degraded
            continuation.yield(.health(currentHealth))
            continuation.yield(.failed(wrapped))
            throw wrapped
        }
    }

    public func route(for session: AdapterSession) async -> AdapterContentRoute {
        selection(for: session).route
    }

    public func selection(for session: AdapterSession) -> HerdrRouteSelection {
        if let existing = selections[session.id] { return existing }
        let selected = selector.select(
            isKnownAgent: agentSessionIDs.contains(session.id),
            availability: availability,
            failedRoutes: failedRoutes[session.id] ?? []
        )
        selections[session.id] = selected
        return selected
    }

    public func failRoute(
        for session: AdapterSession,
        route: AdapterContentRoute,
        reason: String
    ) -> HerdrRouteSelection {
        var failures = failedRoutes[session.id] ?? []
        failures.insert(route)
        failedRoutes[session.id] = failures
        let fallback = selector.select(
            isKnownAgent: agentSessionIDs.contains(session.id),
            availability: availability,
            failedRoutes: failures
        )
        let disclosed = HerdrRouteSelection(
            route: fallback.route,
            reason: "\(route.rawValue) failed: \(reason). \(fallback.reason)"
        )
        selections[session.id] = disclosed
        currentHealth = .degraded
        continuation.yield(.health(.degraded))
        return disclosed
    }

    public func restartRouteSelection(
        for session: AdapterSession,
        reason: String
    ) -> HerdrRouteSelection {
        failedRoutes[session.id] = []
        let selected = selector.select(
            isKnownAgent: agentSessionIDs.contains(session.id),
            availability: availability
        )
        let disclosed = HerdrRouteSelection(
            route: selected.route,
            reason: "\(reason). \(selected.reason)"
        )
        selections[session.id] = disclosed
        return disclosed
    }

    public func updateAvailability(_ newAvailability: HerdrRouteAvailability) {
        var effective = newAvailability
        effective.snapshotReadAvailable =
            newAvailability.snapshotReadAvailable && client.supportsPaneRead
        availability = effective
    }

    public func focus(session: AdapterSession, bound: AttemptBound) async throws {
        guard session.host == endpoint.host else {
            throw makeError(
                HerdrClientError.commandFailed(
                    argv: [],
                    cause: "session belongs to \(session.host.rawValue), not \(endpoint.host.rawValue)"
                ),
                operation: "focus"
            )
        }
        do {
            try await client.focus(paneID: session.paneID, bound: bound)
        } catch {
            let wrapped = makeError(error, operation: "agent.focus")
            continuation.yield(.failed(wrapped))
            throw wrapped
        }
        continuation.yield(.focusChanged(sessionID: session.id))
        _ = try? await refresh(trigger: .explicitFocus, bound: bound)
    }

    public nonisolated func attachCommand(
        for session: AdapterSession,
        route: AdapterContentRoute
    ) -> [String] {
        switch route {
        case .fullClient:
            if endpoint.executionSite == .local { return ["herdr"] }
            return ["herdr", "--remote", session.host.rawValue]
        case .agentAttach:
            return commandOnSessionHost(
                session,
                arguments: ["agent", "attach", session.paneID, "--takeover"]
            )
        case .readOnlySnapshot:
            return commandOnSessionHost(
                session,
                arguments: [
                    "pane", "read", session.paneID,
                    "--source", "visible", "--format", "ansi",
                ]
            )
        case .ordinarySSH:
            return commandOnSessionHost(session, arguments: [])
        }
    }

    public func readSnapshot(
        for session: AdapterSession,
        trigger: HerdrSnapshotTrigger,
        bound: AttemptBound
    ) async throws -> HerdrPaneSnapshotObservation {
        let selected = selection(for: session)
        guard selected.route == .readOnlySnapshot else {
            throw makeError(
                HerdrClientError.commandFailed(
                    argv: attachCommand(for: session, route: selected.route),
                    cause: "selected route is \(selected.route.rawValue), not readOnlySnapshot"
                ),
                operation: "pane.read"
            )
        }

        do {
            let read = try await client.readPane(session.paneID, trigger: trigger, bound: bound)
            if let retained = retainedSnapshots[session.id], read.revision < retained.read.revision {
                throw HerdrClientError.malformedResponse(
                    operation: "pane.read",
                    cause: "revision regressed from \(retained.read.revision) to \(read.revision)"
                )
            }
            let observation = HerdrPaneSnapshotObservation(
                read: read,
                observedAt: clock.now,
                trigger: trigger
            )
            retainedSnapshots[session.id] = observation
            return observation
        } catch {
            availability.snapshotReadAvailable = false
            let wrapped = makeError(error, operation: "pane.read")
            let fallback = failRoute(
                for: session,
                route: .readOnlySnapshot,
                reason: wrapped.cause
            )
            throw HerdrRouteTransitionError(failure: wrapped, selection: fallback)
        }
    }

    public func retainedSnapshot(for sessionID: String) -> HerdrPaneSnapshotObservation? {
        retainedSnapshots[sessionID]
    }

    public func session(
        host: HostAlias,
        workspace: String,
        paneID: String
    ) -> AdapterSession? {
        currentSessions.first {
            $0.host == host && $0.workspace == workspace && $0.paneID == paneID
        }
    }

    private nonisolated func commandOnSessionHost(
        _ session: AdapterSession,
        arguments: [String]
    ) -> [String] {
        if endpoint.executionSite == .local, session.host == endpoint.host {
            return ["herdr"] + arguments
        }
        return ["ssh", session.host.rawValue, "herdr"] + arguments
    }

    private func consume(_ event: HerdrEventEnvelope) async {
        switch event.event {
        case .paneFocused:
            if let paneID = event.data.paneID,
               let session = currentSessions.first(where: { $0.paneID == paneID })
            {
                continuation.yield(.focusChanged(sessionID: session.id))
            }
        case .paneAgentStatusChanged, .paneAgentStatusChangedSubscription:
            guard let paneID = event.data.paneID, let status = event.data.agentStatus else {
                await refreshFromVerifiedEvent()
                return
            }
            guard let index = currentSessions.firstIndex(where: { $0.paneID == paneID }) else {
                await refreshFromVerifiedEvent()
                return
            }
            currentSessions[index].agentState = mapper.agentState(from: status)
            currentSessions[index].observedAt = clock.now
            continuation.yield(.sessions(currentSessions))
        case .paneOutputMatchedSubscription:
            await refreshFromVerifiedEvent()
        case .workspaceCreated, .workspaceUpdated, .workspaceClosed, .workspaceRenamed,
             .workspaceMoved, .tabCreated, .tabClosed, .tabRenamed, .tabMoved,
             .paneCreated, .paneClosed, .paneMoved, .paneExited, .paneAgentDetected:
            await refreshFromVerifiedEvent()
        case .workspaceFocused, .tabFocused, .paneOutputChanged, .layoutUpdated,
             .paneScrollChangedSubscription:
            break
        }
    }

    private func refreshFromVerifiedEvent() async {
        _ = try? await refresh(trigger: .verifiedEvent, bound: .controlRequest)
    }

    private func publishFailure(_ error: Error, operation: String) {
        let wrapped = makeError(error, operation: operation)
        currentHealth = currentSessions.isEmpty ? .error : .degraded
        continuation.yield(.health(currentHealth))
        continuation.yield(.failed(wrapped))
    }

    private func acceptRevisions(from snapshot: HerdrSnapshot) throws {
        var incoming = Dictionary(
            snapshot.panes.map { ($0.paneID, $0.revision) },
            uniquingKeysWith: max
        )
        for agent in snapshot.agents {
            incoming[agent.paneID] = max(incoming[agent.paneID] ?? 0, agent.revision)
        }
        for (paneID, revision) in incoming {
            if let retained = paneRevisions[paneID], revision < retained {
                throw HerdrClientError.malformedResponse(
                    operation: "session.snapshot",
                    cause: "pane \(paneID) revision regressed from \(retained) to \(revision)"
                )
            }
        }
        paneRevisions = incoming
    }

    private func makeError(_ error: Error, operation: String) -> AllwardError {
        if let allwardError = error as? AllwardError { return allwardError }
        let retryability: AllwardError.Retryability = error is CancellationError
            ? .cancelled
            : .retryable
        return AllwardError(
            domain: .adapter,
            operation: operation,
            cause: String(describing: error),
            retryability: retryability,
            recovery: "Retry the herdr operation or use the disclosed fallback route"
        )
    }
}

public struct HerdrRouteTransitionError: Error, Hashable, Sendable, CustomStringConvertible {
    public var failure: AllwardError
    public var selection: HerdrRouteSelection

    public init(failure: AllwardError, selection: HerdrRouteSelection) {
        self.failure = failure
        self.selection = selection
    }

    public var description: String {
        "\(failure.description). Selected \(selection.route.rawValue): \(selection.reason)"
    }
}

public struct HerdrPaneSnapshotObservation: Hashable, Sendable {
    public var read: HerdrPaneRead
    public var observedAt: Date
    public var trigger: HerdrSnapshotTrigger

    public init(read: HerdrPaneRead, observedAt: Date, trigger: HerdrSnapshotTrigger) {
        self.read = read
        self.observedAt = observedAt
        self.trigger = trigger
    }

    public var isLive: Bool { false }
}
