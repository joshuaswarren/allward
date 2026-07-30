import AllwardCore
import Foundation

public enum HerdrExecutionSite: Hashable, Sendable {
    case local
    case ssh
}

public struct HerdrEndpoint: Hashable, Sendable {
    public var host: HostAlias
    public var executionSite: HerdrExecutionSite

    public init(host: HostAlias, executionSite: HerdrExecutionSite) {
        self.host = host
        self.executionSite = executionSite
    }

    public func argv(for arguments: [String]) -> [String] {
        switch executionSite {
        case .local:
            ["herdr"] + arguments
        case .ssh:
            ["ssh", host.rawValue, "herdr"] + arguments
        }
    }
}

public enum HerdrSnapshotTrigger: String, Hashable, Sendable, CaseIterable {
    case initialOpen
    case explicitFocus
    case manualRefresh
    case reconnectResync
    case verifiedEvent
}

/// Executors must terminate their owned process or socket request when task cancellation arrives.
public typealias HerdrCommandExecutor = @Sendable ([String]) async throws -> Data
/// Executors must terminate their owned process or socket request when task cancellation arrives.
public typealias HerdrSocketRequestExecutor = @Sendable (Data) async throws -> Data
public typealias HerdrEventFrameSource = @Sendable () -> AsyncStream<Data>

public enum HerdrClientError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidBound
    case timedOut(argv: [String])
    case commandFailed(argv: [String], cause: String)
    case malformedResponse(operation: String, cause: String)
    case incompatibleServer(version: String, protocolVersion: UInt32)
    case socketMethodUnavailable(String)
    case socketTimedOut(String)
    case socketRequestFailed(method: String, cause: String)

    public var description: String {
        switch self {
        case .invalidBound:
            "Attempt bound must have positive timeouts"
        case .timedOut(let argv):
            "Timed out: \(argv.joined(separator: " "))"
        case .commandFailed(let argv, let cause):
            "Command failed (\(argv.joined(separator: " "))): \(cause)"
        case .malformedResponse(let operation, let cause):
            "Malformed \(operation) response: \(cause)"
        case .incompatibleServer(let version, let protocolVersion):
            "Expected herdr 0.7.5 protocol 17, received \(version) protocol \(protocolVersion)"
        case .socketMethodUnavailable(let method):
            "The herdr socket executor does not provide \(method)"
        case .socketTimedOut(let method):
            "Socket method timed out: \(method)"
        case .socketRequestFailed(let method, let cause):
            "Socket method failed (\(method)): \(cause)"
        }
    }
}

/// Schema evidence: `AgentStatus` is exactly `idle|working|blocked|done|unknown`.
public enum HerdrAgentStatus: String, Codable, Hashable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown
}

/// Schema evidence: `WorkspaceInfo` defines `workspace_id`, `label`, `focused`, and `active_tab_id`.
public struct HerdrWorkspace: Codable, Hashable, Sendable {
    public var workspaceID: String
    public var label: String
    public var focused: Bool
    public var activeTabID: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
        case focused
        case activeTabID = "active_tab_id"
    }
}

/// Schema evidence: `AgentInfo` defines these terminal, workspace, pane, state, cwd, focus, and revision fields.
public struct HerdrAgent: Codable, Hashable, Sendable {
    public var terminalID: String
    public var agent: String?
    public var agentStatus: HerdrAgentStatus
    public var workspaceID: String
    public var tabID: String
    public var paneID: String
    public var focused: Bool
    public var revision: UInt64
    public var cwd: String?
    public var foregroundCwd: String?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agent
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case revision
        case cwd
        case foregroundCwd = "foreground_cwd"
        case title
    }
}

/// Schema evidence: `PaneInfo` defines these pane, terminal, workspace, agent, cwd, focus, and revision fields.
public struct HerdrPane: Codable, Hashable, Sendable {
    public var paneID: String
    public var terminalID: String
    public var workspaceID: String
    public var tabID: String
    public var focused: Bool
    public var agentStatus: HerdrAgentStatus
    public var revision: UInt64
    public var agent: String?
    public var cwd: String?
    public var foregroundCwd: String?
    public var title: String?
    public var label: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused
        case agentStatus = "agent_status"
        case revision
        case agent
        case cwd
        case foregroundCwd = "foreground_cwd"
        case title
        case label
    }
}

/// Schema evidence: `SessionSnapshot` defines version, protocol, workspaces, panes, agents, and focused pane ID.
public struct HerdrSnapshot: Codable, Hashable, Sendable {
    public var version: String
    public var protocolVersion: UInt32
    public var workspaces: [HerdrWorkspace]
    public var panes: [HerdrPane]
    public var agents: [HerdrAgent]
    public var focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case workspaces
        case panes
        case agents
        case focusedPaneID = "focused_pane_id"
    }
}

/// Schema evidence: the `session_snapshot` result requires `type` and `snapshot`.
public struct HerdrSnapshotResult: Codable, Hashable, Sendable {
    public var type: String
    public var snapshot: HerdrSnapshot
}

/// Schema evidence: `SuccessResponse` requires top-level `id` and `result`.
public struct HerdrSnapshotEnvelope: Codable, Hashable, Sendable {
    public var id: String
    public var result: HerdrSnapshotResult
}

/// Schema evidence: the `agent_list` result requires `type` and `agents`.
public struct HerdrAgentListResult: Codable, Hashable, Sendable {
    public var type: String
    public var agents: [HerdrAgent]
}

/// Schema evidence: `SuccessResponse` requires top-level `id` and `result`.
public struct HerdrAgentListEnvelope: Codable, Hashable, Sendable {
    public var id: String
    public var result: HerdrAgentListResult
}

/// Schema evidence: `PaneReadResult` defines pane/workspace/tab IDs, source, format, text, revision, and truncation.
public struct HerdrPaneRead: Codable, Hashable, Sendable {
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var source: String
    public var format: String
    public var text: String
    public var revision: UInt64
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case source
        case format
        case text
        case revision
        case truncated
    }
}

/// Schema evidence: the `pane_read` result requires `type` and `read`.
public struct HerdrPaneReadResult: Codable, Hashable, Sendable {
    public var type: String
    public var read: HerdrPaneRead
}

/// Schema evidence: `SuccessResponse` requires top-level `id` and `result`.
public struct HerdrPaneReadEnvelope: Codable, Hashable, Sendable {
    public var id: String
    public var result: HerdrPaneReadResult
}

/// Schema evidence: `PaneReadParams` defines `pane_id`, `source`, `format`, and `strip_ansi`.
public struct HerdrPaneReadParameters: Codable, Hashable, Sendable {
    public var paneID: String
    public var source: String
    public var format: String
    public var stripANSI: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case format
        case stripANSI = "strip_ansi"
    }
}

/// Schema evidence: a `pane.read` request requires `id`, `method`, and `params`.
public struct HerdrPaneReadRequest: Codable, Hashable, Sendable {
    public var id: String
    public var method: String
    public var params: HerdrPaneReadParameters
}

/// Schema evidence: `EventKind` and `SubscriptionEventKind` list every event string represented here.
public enum HerdrEventKind: String, Codable, Hashable, Sendable {
    case workspaceCreated = "workspace_created"
    case workspaceUpdated = "workspace_updated"
    case workspaceClosed = "workspace_closed"
    case workspaceRenamed = "workspace_renamed"
    case workspaceMoved = "workspace_moved"
    case workspaceFocused = "workspace_focused"
    case tabCreated = "tab_created"
    case tabClosed = "tab_closed"
    case tabRenamed = "tab_renamed"
    case tabMoved = "tab_moved"
    case tabFocused = "tab_focused"
    case paneCreated = "pane_created"
    case paneClosed = "pane_closed"
    case paneFocused = "pane_focused"
    case paneMoved = "pane_moved"
    case paneOutputChanged = "pane_output_changed"
    case paneExited = "pane_exited"
    case paneAgentDetected = "pane_agent_detected"
    case paneAgentStatusChanged = "pane_agent_status_changed"
    case layoutUpdated = "layout_updated"
    case paneOutputMatchedSubscription = "pane.output_matched"
    case paneAgentStatusChangedSubscription = "pane.agent_status_changed"
    case paneScrollChangedSubscription = "pane.scroll_changed"
}

/// Schema evidence: event data defines type, pane/workspace IDs, revision, and agent status where applicable.
public struct HerdrEventData: Codable, Hashable, Sendable {
    public var type: HerdrEventKind?
    public var paneID: String?
    public var workspaceID: String?
    public var revision: UInt64?
    public var agentStatus: HerdrAgentStatus?

    enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case revision
        case agentStatus = "agent_status"
    }
}

/// Schema evidence: `EventEnvelope` requires `event` and `data`.
public struct HerdrEventEnvelope: Codable, Hashable, Sendable {
    public var event: HerdrEventKind
    public var data: HerdrEventData
}

public struct HerdrSocketClient: Sendable {
    public let endpoint: HerdrEndpoint
    private let executor: HerdrCommandExecutor
    private let socketExecutor: HerdrSocketRequestExecutor?
    private let eventSource: HerdrEventFrameSource?

    public init(
        endpoint: HerdrEndpoint,
        executor: @escaping HerdrCommandExecutor,
        socketExecutor: HerdrSocketRequestExecutor? = nil,
        eventSource: HerdrEventFrameSource? = nil
    ) {
        self.endpoint = endpoint
        self.executor = executor
        self.socketExecutor = socketExecutor
        self.eventSource = eventSource
    }

    public var hasEventSource: Bool { eventSource != nil }
    public var supportsPaneRead: Bool { socketExecutor != nil }

    public func eventFrames() -> AsyncStream<Data> {
        eventSource?() ?? AsyncStream { $0.finish() }
    }

    public func snapshot(
        trigger: HerdrSnapshotTrigger,
        bound: AttemptBound
    ) async throws -> HerdrSnapshot {
        let data = try await execute(arguments: ["api", "snapshot"], bound: bound)
        let envelope: HerdrSnapshotEnvelope = try decode(data, operation: "session.snapshot")
        guard envelope.result.type == "session_snapshot" else {
            throw HerdrClientError.malformedResponse(
                operation: "session.snapshot",
                cause: "result type was \(envelope.result.type)"
            )
        }
        let snapshot = envelope.result.snapshot
        guard snapshot.version == "0.7.5", snapshot.protocolVersion == 17 else {
            throw HerdrClientError.incompatibleServer(
                version: snapshot.version,
                protocolVersion: snapshot.protocolVersion
            )
        }
        return snapshot
    }

    public func agents(bound: AttemptBound) async throws -> [HerdrAgent] {
        let data = try await execute(arguments: ["agent", "list"], bound: bound)
        let envelope: HerdrAgentListEnvelope = try decode(data, operation: "agent.list")
        guard envelope.result.type == "agent_list" else {
            throw HerdrClientError.malformedResponse(
                operation: "agent.list",
                cause: "result type was \(envelope.result.type)"
            )
        }
        return envelope.result.agents
    }

    public func readPane(
        _ paneID: String,
        trigger: HerdrSnapshotTrigger,
        bound: AttemptBound
    ) async throws -> HerdrPaneRead {
        guard socketExecutor != nil else {
            throw HerdrClientError.socketMethodUnavailable("pane.read")
        }
        let request = HerdrPaneReadRequest(
            id: "allward:pane.read:\(UUID().uuidString)",
            method: "pane.read",
            params: HerdrPaneReadParameters(
                paneID: paneID,
                source: "visible",
                format: "ansi",
                stripANSI: false
            )
        )
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw HerdrClientError.malformedResponse(
                operation: "pane.read request",
                cause: String(describing: error)
            )
        }
        let data = try await executeSocket(requestData, method: "pane.read", bound: bound)
        let envelope: HerdrPaneReadEnvelope = try decode(data, operation: "pane.read")
        guard envelope.result.type == "pane_read" else {
            throw HerdrClientError.malformedResponse(
                operation: "pane.read",
                cause: "result type was \(envelope.result.type)"
            )
        }
        return envelope.result.read
    }

    public func focus(paneID: String, bound: AttemptBound) async throws {
        _ = try await execute(arguments: ["agent", "focus", paneID], bound: bound)
    }

    public func decodeEvent(_ data: Data) throws -> HerdrEventEnvelope {
        let envelope: HerdrEventEnvelope = try decode(data, operation: "event")
        if let dataType = envelope.data.type, dataType != envelope.event {
            throw HerdrClientError.malformedResponse(
                operation: "event",
                cause: "envelope event \(envelope.event.rawValue) disagrees with data type \(dataType.rawValue)"
            )
        }
        return envelope
    }

    public func argv(for arguments: [String]) -> [String] {
        endpoint.argv(for: arguments)
    }

    private func decode<Value: Decodable>(_ data: Data, operation: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw HerdrClientError.malformedResponse(
                operation: operation,
                cause: String(describing: error)
            )
        }
    }

    private func execute(arguments: [String], bound: AttemptBound) async throws -> Data {
        guard bound.perAttemptTimeout > 0, bound.totalTimeout > 0 else {
            throw HerdrClientError.invalidBound
        }
        let argv = endpoint.argv(for: arguments)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(bound.totalTimeout))
        var lastFailure: String?

        for _ in 0..<bound.maxAttempts {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw HerdrClientError.timedOut(argv: argv) }
            let timeout = min(remaining, .seconds(bound.perAttemptTimeout))

            do {
                return try await executeAttempt(argv: argv, timeout: timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = String(describing: error)
            }
        }

        throw HerdrClientError.commandFailed(
            argv: argv,
            cause: lastFailure ?? "attempt bound exhausted"
        )
    }

    private func executeSocket(
        _ request: Data,
        method: String,
        bound: AttemptBound
    ) async throws -> Data {
        guard let socketExecutor else {
            throw HerdrClientError.socketMethodUnavailable(method)
        }
        guard bound.perAttemptTimeout > 0, bound.totalTimeout > 0 else {
            throw HerdrClientError.invalidBound
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(bound.totalTimeout))
        var lastFailure: String?

        for _ in 0..<bound.maxAttempts {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw HerdrClientError.socketTimedOut(method) }
            let timeout = min(remaining, .seconds(bound.perAttemptTimeout))

            do {
                return try await executeSocketAttempt(
                    request: request,
                    method: method,
                    timeout: timeout,
                    executor: socketExecutor
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = String(describing: error)
            }
        }

        throw HerdrClientError.socketRequestFailed(
            method: method,
            cause: lastFailure ?? "attempt bound exhausted"
        )
    }

    private func executeSocketAttempt(
        request: Data,
        method: String,
        timeout: Duration,
        executor: @escaping HerdrSocketRequestExecutor
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await executor(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HerdrClientError.socketTimedOut(method)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HerdrClientError.socketRequestFailed(
                    method: method,
                    cause: "executor returned no result"
                )
            }
            return result
        }
    }

    private func executeAttempt(argv: [String], timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await executor(argv) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HerdrClientError.timedOut(argv: argv)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HerdrClientError.commandFailed(argv: argv, cause: "executor returned no result")
            }
            return result
        }
    }
}
