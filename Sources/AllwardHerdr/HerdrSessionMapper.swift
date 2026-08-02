import AllwardCore
import AllwardMultiplexer
import Foundation

public struct HerdrMappedSessions: Hashable, Sendable {
    public var sessions: [AdapterSession]
    public var agentSessionIDs: Set<String>

    public init(sessions: [AdapterSession], agentSessionIDs: Set<String>) {
        self.sessions = sessions
        self.agentSessionIDs = agentSessionIDs
    }
}

public struct HerdrSessionMapper: Sendable {
    private let clock: any AllwardClock

    public init(clock: any AllwardClock = SystemClock()) {
        self.clock = clock
    }

    public func map(snapshot: HerdrSnapshot, host: HostAlias) -> HerdrMappedSessions {
        let observedAt = clock.now
        let workspaceLabels = Dictionary(
            uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.label) }
        )
        let agentsByPane = Dictionary(
            snapshot.agents.map { ($0.paneID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var sessions: [AdapterSession] = []
        var mappedPaneIDs: Set<String> = []
        var agentSessionIDs: Set<String> = []

        for pane in snapshot.panes {
            let agent = agentsByPane[pane.paneID]
            let session = makeSession(
                host: host,
                workspaceID: pane.workspaceID,
                workspaceLabel: workspaceLabels[pane.workspaceID],
                paneID: pane.paneID,
                terminalID: pane.terminalID,
                // The agent's own title first: a pane running an agent is
                // known by the agent, not by whatever the shell last set.
                title: agent?.title ?? pane.title ?? pane.label ?? agent?.agent,
                status: agent?.agentStatus ?? pane.agentStatus,
                workingDirectory: agent?.foregroundCwd ?? agent?.cwd ?? pane.foregroundCwd ?? pane.cwd,
                observedAt: observedAt
            )
            sessions.append(session)
            mappedPaneIDs.insert(pane.paneID)
            if agent != nil || pane.agent != nil {
                agentSessionIDs.insert(session.id)
            }
        }

        for agent in snapshot.agents where !mappedPaneIDs.contains(agent.paneID) {
            let session = makeSession(
                host: host,
                workspaceID: agent.workspaceID,
                workspaceLabel: workspaceLabels[agent.workspaceID],
                paneID: agent.paneID,
                terminalID: agent.terminalID,
                title: agent.title ?? agent.agent,
                status: agent.agentStatus,
                workingDirectory: agent.foregroundCwd ?? agent.cwd,
                observedAt: observedAt
            )
            sessions.append(session)
            agentSessionIDs.insert(session.id)
        }

        sessions.sort {
            ($0.workspace, $0.paneID, $0.id) < ($1.workspace, $1.paneID, $1.id)
        }
        return HerdrMappedSessions(sessions: sessions, agentSessionIDs: agentSessionIDs)
    }

    public func agentState(from status: HerdrAgentStatus) -> AgentState {
        switch status {
        case .working: .working
        case .blocked: .blocked
        case .idle: .idle
        case .done: .done
        case .unknown: .unknown
        }
    }

    private func makeSession(
        host: HostAlias,
        workspaceID: String,
        workspaceLabel: String?,
        paneID: String,
        terminalID: String,
        title: String?,
        status: HerdrAgentStatus,
        workingDirectory: String?,
        observedAt: Date
    ) -> AdapterSession {
        AdapterSession(
            id: "herdr:\(host.rawValue):\(workspaceID):\(paneID)",
            // The Board is read by a person, so the space carries the name
            // herdr shows for it. The identifier stays in `id`, where it is
            // needed for routing and nowhere else.
            workspace: workspaceLabel ?? workspaceID,
            paneID: paneID,
            host: host,
            title: title ?? terminalID,
            agentState: agentState(from: status),
            workingDirectory: workingDirectory,
            observedAt: observedAt
        )
    }
}
