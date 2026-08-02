import AllwardCore
import AllwardMultiplexer
import AllwardRemote
import AllwardRooms
import AllwardSurfaces
import AllwardTerminal
import Foundation

public protocol ControlRequestHandling: Sendable {
    func handle(_ request: ControlRequest) async -> ControlResponse
}

public protocol ControlSocketServing: Sendable {
    func start(handler: any ControlRequestHandling, at path: String) throws
    func stop()
}

/// The platform capabilities a product supplies, so shared code never imports
/// one.
///
/// `AllwardPlatformDevID` spawns local shells, reads the process table, and binds
/// an AF_UNIX control socket. `AllwardPlatformMAS` does none of those, which is
/// why SPEC §2 can require the difference to be a fact about the link graph
/// rather than a runtime check that could be wrong.
///
/// Nothing here returns a path or a process. A container layout is the platform's
/// business, so the socket is started rather than located, and the adapter is
/// built rather than described.
public protocol PlatformServices: Sendable {
    /// Transports the control layer may use, in preference order. The Developer
    /// ID product offers a local shell; MAS is remote-only and does not.
    var transports: [any RemoteTransport] { get }

    /// Starts the control socket the MCP helper connects to, and returns the
    /// running host so it can be stopped. `nil` means this product owns no
    /// listener path, which is not an error.
    func startControlSocket(
        handler: any ControlRequestHandling
    ) throws -> (any ControlSocketServing)?

    /// The multiplexer adapter for a host, or a no-adapter state. Adapter
    /// construction lives here so no shared target links the adapter.
    func makeMultiplexerAdapter(host: HostAlias?) -> any MultiplexerAdapter

    /// A herdr this product can find without being told, or `nil` where servers
    /// must be declared. Discovery reads the process table, so MAS has none.
    func discoverAdapterHost() async -> HostAlias?

    /// Publishes the configured hosts an SSH alias resolves against.
    ///
    /// Configuration reloads while sessions are open, so this is called again on
    /// every reload rather than read once at launch. It replaces the set: a host
    /// removed from the file must stop resolving.
    func apply(hosts: [RemoteHost])
}

public struct ControlAdapterSession: Codable, Hashable, Sendable {
    public var id: String
    public var workspace: String
    public var paneID: String
    public var host: HostAlias
    public var title: String
    public var agentState: AgentState
    public var workingDirectory: String?
    public var observedAt: Date

    public init(_ session: AdapterSession) {
        id = session.id
        workspace = session.workspace
        paneID = session.paneID
        host = session.host
        title = session.title
        agentState = session.agentState
        workingDirectory = session.workingDirectory
        observedAt = session.observedAt
    }

    var adapterSession: AdapterSession {
        AdapterSession(
            id: id,
            workspace: workspace,
            paneID: paneID,
            host: host,
            title: title,
            agentState: agentState,
            workingDirectory: workingDirectory,
            observedAt: observedAt
        )
    }
}

public enum ControlTeleportDestination: Codable, Hashable, Sendable {
    case pane(PaneID)
    case adapter(ControlAdapterSession)

    var destination: TeleportDestination {
        switch self {
        case let .pane(pane): TeleportDestination(pane: pane)
        case let .adapter(session): TeleportDestination(adapterSession: session.adapterSession)
        }
    }
}

public enum ControlKey: Codable, Hashable, Sendable {
    case character(String)
    case up
    case down
    case right
    case left
    case home
    case end
    case insert
    case delete
    case pageUp
    case pageDown
    case enter
    case tab
    case backtab
    case escape
    case backspace
    case function(Int)

    var terminalKey: AllwardTerminal.TerminalKey {
        switch self {
        case let .character(value): .character(value)
        case .up: .up
        case .down: .down
        case .right: .right
        case .left: .left
        case .home: .home
        case .end: .end
        case .insert: .insert
        case .delete: .delete
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .enter: .enter
        case .tab: .tab
        case .backtab: .backtab
        case .escape: .escape
        case .backspace: .backspace
        case let .function(number): .function(number)
        }
    }
}

public struct ControlAuthoredContent: Codable, Hashable, Sendable {
    public var kind: NormalizedRecord.Kind
    public var title: String
    public var detail: String?
    public var agentState: String?

    public init(kind: NormalizedRecord.Kind, title: String, detail: String? = nil, agentState: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.agentState = agentState
    }

    var authoredContent: MCPAuthoredContent {
        MCPAuthoredContent(kind: kind, title: title, detail: detail, agentState: agentState)
    }
}

public struct ControlAuthoredAuthority: Codable, Hashable, Sendable {
    public var authoritativeClientID: String
    public var grantID: String
    public var grantInvocationNamespace: String

    public init(
        authoritativeClientID: String,
        grantID: String,
        grantInvocationNamespace: String
    ) {
        self.authoritativeClientID = authoritativeClientID
        self.grantID = grantID
        self.grantInvocationNamespace = grantInvocationNamespace
    }

    var authoredAuthority: MCPAuthoredAuthority {
        MCPAuthoredAuthority(
            authoritativeClientID: authoritativeClientID,
            grantID: grantID,
            grantInvocationNamespace: grantInvocationNamespace
        )
    }
}

public struct ControlInputRouteLock: Codable, Hashable, Sendable {
    public var handle: UUID
    public var routeGeneration: Generation
    public var ownershipGeneration: Generation

    public init(
        handle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation
    ) {
        self.handle = handle
        self.routeGeneration = routeGeneration
        self.ownershipGeneration = ownershipGeneration
    }
}

public enum ControlRequest: Codable, Hashable, Sendable {
    case createLocalPane(Target, Generation, PaneCreationRequest, IdempotencyKey)
    case createSSHPane(Target, Generation, PaneCreationRequest, HostAlias, [String]?, IdempotencyKey)
    case attachAdapterPane(Target, Generation, WindowID, TabID, TerminalGeometry, ControlAdapterSession, IdempotencyKey)
    case closePane(Target, Generation, IdempotencyKey)
    case splitPane(Target, Generation, RemoteDestination, SplitOrientation, Double, TerminalGeometry, IdempotencyKey)
    case focusPane(Target, Generation, IdempotencyKey)
    case movePaneFocus(Target, Generation, FocusDirection, IdempotencyKey)
    case resizePane(Target, Generation, Int, Int, IdempotencyKey)
    case sendText(Target, Generation, String, PaneInputSource, IdempotencyKey)
    case sendKeys(Target, Generation, [ControlKey], PaneInputSource, IdempotencyKey)
    case lockInputRoute(PaneID)
    case isRouteCurrent(PaneID, UUID, Generation, Generation)
    case injectText(String, PaneID, UUID, Generation, Generation)
    case readScreen(PaneID)
    case readHistory(PaneID, Int)
    case lastCommand(PaneID)
    case exitCode(PaneID)
    case readScreenTarget(Target)
    case readHistoryTarget(Target, Int)
    case lastCommandTarget(Target)
    case exitCodeTarget(Target)
    case listPanes
    case createTab(Target, Generation, WindowID, TabID, IdempotencyKey)
    case closeTab(Target, Generation, WindowID, TabID, IdempotencyKey)
    case setRoom(WindowID, RoomID, Target, Generation, IdempotencyKey)
    case teleport(Target, Generation, ControlTeleportDestination, IdempotencyKey)
    case runCommand(Target, Generation, String, AttemptBound, IdempotencyKey)
    case recoverCommandReceipt(IdempotencyKey)
    case boardSnapshot
    case routerSnapshot
    case listRooms
    case createAuthoredRecord(
        Target,
        Generation,
        String,
        ControlAuthoredContent,
        ControlAuthoredAuthority,
        UUID,
        IdempotencyKey
    )
    case updateAuthoredRecord(
        Target,
        Generation,
        String,
        ControlAuthoredContent,
        ControlAuthoredAuthority,
        UUID,
        UInt64,
        IdempotencyKey
    )
    case endAuthoredRecord(
        Target,
        Generation,
        String,
        ControlAuthoredAuthority,
        UUID,
        UInt64,
        String,
        IdempotencyKey
    )
    case staleMCPAuthority(namespace: String)
}

public enum ControlResponse: Codable, Hashable, Sendable {
    case mutation(ControlMutationResult)
    case screen(ScreenRead?)
    case history([String]?)
    case command(CommandRegion?)
    case exitCode(Int32?)
    case topology(TopologySnapshot)
    case runCommand(RunCommandResult)
    case commandReceipt(CommandExecutionReceipt?)
    case board(BoardSnapshot)
    case router(RouterSnapshot)
    case rooms([Room])
    case authored(AuthoredMutationResult)
    case inputRoute(ControlInputRouteLock?)
    case boolean(Bool)
    case failure(AllwardError)
    case acknowledged
}
