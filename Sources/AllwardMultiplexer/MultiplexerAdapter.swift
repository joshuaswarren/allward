import AllwardCore
import Foundation

// The optional adapter seam of SPEC §5. Core code depends on this module only.
// No core target may import `AllwardHerdr`; `AllwardNoHerdrTarget` proves it.

/// What an adapter can actually do. Callers must never infer missing core
/// terminal, Room, protocol, MCP, STT, split, tab, or board behaviour from
/// adapter absence.
public struct AdapterCapabilities: Hashable, Sendable, Codable {
    public var discoversSessions: Bool
    public var durableWorkspaceIdentity: Bool
    public var teleport: Bool
    public var focusSynchronization: Bool
    public var coarseAgentState: Bool

    public init(
        discoversSessions: Bool = false,
        durableWorkspaceIdentity: Bool = false,
        teleport: Bool = false,
        focusSynchronization: Bool = false,
        coarseAgentState: Bool = false
    ) {
        self.discoversSessions = discoversSessions
        self.durableWorkspaceIdentity = durableWorkspaceIdentity
        self.teleport = teleport
        self.focusSynchronization = focusSynchronization
        self.coarseAgentState = coarseAgentState
    }

    public static let none = AdapterCapabilities()
}

/// A session the adapter knows about, normalized away from its own vocabulary.
public struct AdapterSession: Hashable, Sendable, Identifiable {
    public var id: String
    public var workspace: String
    public var paneID: String
    public var host: HostAlias
    public var title: String
    /// Coarse agent state as reported by the adapter, never inferred from pixels.
    public var agentState: AgentState
    public var workingDirectory: String?
    public var observedAt: Date

    public init(
        id: String,
        workspace: String,
        paneID: String,
        host: HostAlias,
        title: String,
        agentState: AgentState = .unknown,
        workingDirectory: String? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.workspace = workspace
        self.paneID = paneID
        self.host = host
        self.title = title
        self.agentState = agentState
        self.workingDirectory = workingDirectory
        self.observedAt = observedAt
    }
}

/// Coarse agent state an adapter may report.
public enum AgentState: String, Hashable, Sendable, Codable, CaseIterable {
    case working
    case blocked
    case done
    case idle
    case unknown
}

/// The content route an adapter offers for one session, in the exact fallback
/// order of SPEC §5. Presentation must name any non-primary route.
public enum AdapterContentRoute: String, Hashable, Sendable, Codable, CaseIterable {
    case fullClient
    case agentAttach
    case readOnlySnapshot
    case ordinarySSH

    public var isLive: Bool { self != .readOnlySnapshot }

    /// The persistent disclosure a non-primary route must show.
    public var persistentLabel: String? {
        switch self {
        case .fullClient: nil
        case .agentAttach: "Agent-only attach"
        case .readOnlySnapshot: "Read-only snapshot — not live"
        case .ordinarySSH: "Native herdr board and teleport unavailable"
        }
    }
}

public enum AdapterEvent: Sendable {
    case health(AdapterHealth)
    case sessions([AdapterSession])
    case focusChanged(sessionID: String)
    case failed(AllwardError)
}

/// The optional adapter interface. A conforming type owns composition and
/// identity inside its own external workspace and nothing else.
public protocol MultiplexerAdapter: Sendable {
    var displayName: String { get }
    var capabilities: AdapterCapabilities { get }
    var health: AdapterHealth { get async }
    var events: AsyncStream<AdapterEvent> { get }

    func start() async
    func stop() async
    func listSessions(bound: AttemptBound) async throws -> [AdapterSession]
    func route(for session: AdapterSession) async -> AdapterContentRoute
    /// Focus a session inside the adapter's own workspace.
    func focus(session: AdapterSession, bound: AttemptBound) async throws
    /// Argument vector that attaches a terminal to this session over SSH.
    func attachCommand(for session: AdapterSession, route: AdapterContentRoute) -> [String]
}

/// The valid no-adapter implementation. Its presence keeps every core surface
/// honest: adapter `none` is normal absence, not an error or a CTA.
public struct NoMultiplexerAdapter: MultiplexerAdapter {
    public init() {}
    public var displayName: String { "None" }
    public var capabilities: AdapterCapabilities { .none }
    public var health: AdapterHealth { get async { .none } }
    public var events: AsyncStream<AdapterEvent> { AsyncStream { $0.finish() } }
    public func start() async {}
    public func stop() async {}
    public func listSessions(bound: AttemptBound) async throws -> [AdapterSession] { [] }
    public func route(for session: AdapterSession) async -> AdapterContentRoute { .ordinarySSH }
    public func focus(session: AdapterSession, bound: AttemptBound) async throws {}
    public func attachCommand(for session: AdapterSession, route: AdapterContentRoute) -> [String] {
        []
    }
}
