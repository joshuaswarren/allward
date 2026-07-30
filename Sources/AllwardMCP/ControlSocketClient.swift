import AllwardControl
import AllwardCore
import AllwardRemote
import AllwardSurfaces
import AllwardTerminal
import Darwin
import Foundation

public enum AppControlSocketError: Error, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case insecureSocket(path: String, reason: String)
    case connectionFailed(path: String, errno: Int32)
    case disconnected
    case writeFailed(Int32)
    case readFailed(Int32)
    case responseTooLarge
    case malformedResponse(String)
    case remoteError(AllwardError)

    public var description: String {
        switch self {
        case let .pathTooLong(path): "The Allward control socket path is too long: \(path)"
        case let .insecureSocket(path, reason): "Refusing Allward control socket at \(path): \(reason)"
        case let .connectionFailed(path, code):
            "Could not connect to the Allward app at \(path) (errno \(code)). Open Allward, then retry."
        case .disconnected: "The Allward app closed its control connection"
        case let .writeFailed(code): "Writing to the Allward app control socket failed (errno \(code))"
        case let .readFailed(code): "Reading from the Allward app control socket failed (errno \(code))"
        case .responseTooLarge: "The Allward app control response exceeded the 8 MiB limit"
        case let .malformedResponse(reason): "The Allward app returned an invalid control response: \(reason)"
        case let .remoteError(error): "Allward control error: \(error.description)"
        }
    }
}

public actor ControlSocketClient: AllwardControlFacade {
    private static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let descriptor: Int32
    private var readBuffer = Data()

    public static func connect(path: String) throws -> ControlSocketClient {
        try validateOwnerSocket(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppControlSocketError.connectionFailed(path: path, errno: errno)
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { storage -> Bool in
            guard pathBytes.count <= storage.count else { return false }
            storage.copyBytes(from: pathBytes)
            return true
        }
        guard copied else {
            Darwin.close(descriptor)
            throw AppControlSocketError.pathTooLong(path)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw AppControlSocketError.connectionFailed(path: path, errno: code)
        }
        return ControlSocketClient(descriptor: descriptor)
    }

    private static func validateOwnerSocket(_ path: String) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw AppControlSocketError.connectionFailed(path: path, errno: ENOENT)
        }
        guard attributes[.type] as? FileAttributeType == .typeSocket else {
            throw AppControlSocketError.insecureSocket(path: path, reason: "path is not a Unix socket")
        }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw AppControlSocketError.insecureSocket(path: path, reason: "socket is not owned by the current user")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? UInt16.max
        guard permissions & 0o077 == 0 else {
            throw AppControlSocketError.insecureSocket(path: path, reason: "group or other users have access")
        }
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    public func listPanes(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let response = try request(.listPanes)
        guard case let .topology(snapshot) = response else { return try unexpected(response, for: "listPanes") }
        let windowByPane = snapshot.windows.reduce(into: [PaneID: WindowID]()) { result, window in
            for pane in window.tabs.flatMap({ $0.tree?.leaves ?? [] }) { result[pane] = window.id }
        }
        let panes = try snapshot.panes.filter { scope.allows($0.target) }.map { pane -> JSONValue in
            guard let window = windowByPane[pane.id] else {
                throw MCPToolError.capabilityUnavailable("The pane is not attached to a receiver-owned window")
            }
            return .object([
                "pane_id": .string(pane.id.rawValue.uuidString.lowercased()),
                "session_id": .string(pane.session.rawValue.uuidString.lowercased()),
                "window_id": .string(window.rawValue.uuidString.lowercased()),
                "target": Self.target(pane.target),
                "route": .string(pane.destination.provenanceLabel),
                "content_route": try Self.encode(pane.contentRoute)
            ])
        }
        return .object([
            "generation": .integer(Int64(snapshot.generation.rawValue)),
            "panes": .array(panes)
        ])
    }

    public func ownerGrantScope(windowID: String? = nil) throws -> MCPGrantTargetScope {
        let response = try request(.listPanes)
        guard case let .topology(snapshot) = response else {
            return try unexpected(response, for: "ownerGrantScope")
        }
        let roomsResponse = try request(.listRooms)
        guard case let .rooms(configuredRooms) = roomsResponse else {
            return try unexpected(roomsResponse, for: "ownerGrantScope")
        }
        let windows: [WindowTopology]
        if let windowID {
            guard let identifier = UUID(uuidString: windowID) else {
                throw MCPToolError.invalidArguments("ALLWARD_WINDOW_ID is not a UUID")
            }
            let selected = WindowID(rawValue: identifier)
            guard let window = snapshot.windows.first(where: { $0.id == selected }) else {
                throw MCPToolError.capabilityUnavailable("ALLWARD_WINDOW_ID is not open in Allward")
            }
            windows = [window]
        } else {
            windows = snapshot.windows
        }
        let paneIDs = Set(windows.flatMap { window in
            window.tabs.flatMap { $0.tree?.leaves ?? [] }
        })
        let panes = snapshot.panes.filter { paneIDs.contains($0.id) }
        return MCPGrantTargetScope(
            rooms: Set(configuredRooms.map(\.id)).union(windows.map(\.room)),
            sessions: Set(panes.map(\.session)),
            panes: paneIDs
        )
    }

    public func screen(target: Target) async throws -> JSONValue {
        let response = try request(.readScreenTarget(target))
        guard case let .screen(screen) = response else { return try unexpected(response, for: "readScreen") }
        guard let screen else { throw MCPToolError.capabilityUnavailable("The target no longer identifies a pane") }
        return try Self.encode(screen)
    }

    public func history(target: Target, lines: Int) async throws -> JSONValue {
        guard let pane = target.pane else { throw MCPToolError.invalidArguments("target.pane_id is required") }
        let response = try request(.readHistoryTarget(target, lines))
        guard case let .history(history) = response else { return try unexpected(response, for: "readHistory") }
        guard let history else { throw MCPToolError.capabilityUnavailable("The target no longer identifies a pane") }
        return .object([
            "pane_id": .string(pane.rawValue.uuidString.lowercased()),
            "lines": .array(history.map(JSONValue.string))
        ])
    }

    public func sendText(
        target: Target, generation: Generation, text: String, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.sendText(target, generation, text, .mcp, Self.idempotencyKey(idempotencyKey)))
    }

    public func sendKeys(
        target: Target, generation: Generation, keys: [String], idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.sendKeys(
            target,
            generation,
            try keys.map { try Self.controlKey(named: $0) },
            .mcp,
            Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func runCommand(
        target: Target,
        generation: Generation,
        command: String,
        bound: MCPRunBound,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        let seconds = Double(bound.timeoutMilliseconds) / 1_000
        let attemptBound = AttemptBound(maxAttempts: 1, perAttemptTimeout: seconds, totalTimeout: seconds)
        let response = try request(.runCommand(
            target, generation, command, attemptBound, Self.idempotencyKey(idempotencyKey)
        ))
        guard case let .runCommand(result) = response else { return try unexpected(response, for: "runCommand") }
        return try Self.encode(Self.bounded(result, maximumBytes: bound.maximumOutputBytes))
    }

    public func recoverCommandReceipt(idempotencyKey: MCPMutationKey) async throws -> JSONValue? {
        let response = try request(.recoverCommandReceipt(Self.idempotencyKey(idempotencyKey)))
        guard case let .commandReceipt(receipt) = response else {
            return try unexpected(response, for: "recoverCommandReceipt")
        }
        return try receipt.map(Self.encode)
    }

    public func lastCommand(target: Target) async throws -> JSONValue {
        let response = try request(.lastCommandTarget(target))
        guard case let .command(command) = response else { return try unexpected(response, for: "lastCommand") }
        return try Self.encode(command)
    }

    public func exitCode(target: Target) async throws -> JSONValue {
        let response = try request(.exitCodeTarget(target))
        guard case let .exitCode(code) = response else { return try unexpected(response, for: "exitCode") }
        return code.map { .integer(Int64($0)) } ?? .null
    }

    public func splitPane(
        target: Target,
        generation: Generation,
        destination: MCPPaneDestination,
        orientation: String,
        ratio: Double,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        guard let splitOrientation = SplitOrientation(rawValue: orientation) else {
            throw MCPToolError.invalidArguments("Unsupported split orientation: \(orientation)")
        }
        return try mutation(.splitPane(
            target,
            generation,
            destination.remoteDestination,
            splitOrientation,
            ratio,
            TerminalGeometry(columns: 80, rows: 24),
            Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func createTab(
        room: RoomID, window: WindowID, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.createTab(
            Target(room: room), generation, window, TabID(rawValue: UUID()), Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func closePane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.closePane(target, generation, Self.idempotencyKey(idempotencyKey)))
    }

    public func focusPane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.focusPane(target, generation, Self.idempotencyKey(idempotencyKey)))
    }

    public func boardSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let response = try request(.boardSnapshot)
        guard case let .board(snapshot) = response else { return try unexpected(response, for: "boardSnapshot") }
        let groups = snapshot.groups.compactMap { group -> BoardGroup? in
            let rows = group.rows.filter { scope.allows($0.target) }
            guard !rows.isEmpty else { return nil }
            return BoardGroup(roomID: group.roomID, host: group.host, workspace: group.workspace, rows: rows)
        }
        let count = groups.reduce(0) { $0 + $1.rows.count }
        return try Self.encode(BoardSnapshot(
            state: groups.isEmpty ? .emptyNoOpenLoops : .populated,
            groups: groups,
            visibleRowCount: count,
            exactTotal: count,
            generation: snapshot.generation
        ))
    }

    public func routerSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let response = try request(.routerSnapshot)
        guard case let .router(snapshot) = response else { return try unexpected(response, for: "routerSnapshot") }
        let items = snapshot.items.filter { scope.allows($0.target) }
        let highest = items.map(\.attentionClass).min()
        return try Self.encode(RouterSnapshot(
            state: highest.map(RouterState.active) ?? .noActionableItems,
            highestPriorityClass: highest,
            totalActionableCount: items.filter(\.isActionable).count,
            filteredCount: snapshot.items.count - items.count,
            roomID: nil,
            freshness: items.first?.freshness,
            destinationKey: items.first?.destinationKey,
            items: items,
            newEpochs: snapshot.newEpochs.filter { id in items.contains(where: { $0.id == id }) },
            generation: snapshot.generation
        ))
    }

    public func listRooms(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let response = try request(.listRooms)
        guard case let .rooms(rooms) = response else { return try unexpected(response, for: "listRooms") }
        return .object(["rooms": .array(try rooms.filter { scope.allows(room: $0.id) }.map(Self.encode))])
    }

    public func setRoom(
        window: WindowID,
        room: RoomID,
        sourceTarget: Target,
        generation: Generation,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.setRoom(
            window, room, sourceTarget, generation, Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func teleport(
        target: Target, generation: Generation, destination: PaneID, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try mutation(.teleport(target, generation, .pane(destination), Self.idempotencyKey(idempotencyKey)))
    }

    public func createAuthoredRecord(
        logicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        generation: Generation,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try authored(.createAuthoredRecord(
            target,
            generation,
            logicalKey,
            ControlAuthoredContent(
                kind: content.kind, title: content.title, detail: content.detail, agentState: content.agentState
            ),
            ControlAuthoredAuthority(
                authoritativeClientID: authority.authoritativeClientID,
                grantID: authority.grantID,
                grantInvocationNamespace: authority.grantInvocationNamespace
            ),
            invocationID,
            Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func updateAuthoredRecord(
        logicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        generation: Generation,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try authored(.updateAuthoredRecord(
            target,
            generation,
            logicalKey,
            ControlAuthoredContent(
                kind: content.kind, title: content.title, detail: content.detail, agentState: content.agentState
            ),
            ControlAuthoredAuthority(
                authoritativeClientID: authority.authoritativeClientID,
                grantID: authority.grantID,
                grantInvocationNamespace: authority.grantInvocationNamespace
            ),
            invocationID,
            expectedRevision,
            Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func endAuthoredRecord(
        logicalKey: String,
        target: Target,
        generation: Generation,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try authored(.endAuthoredRecord(
            target,
            generation,
            logicalKey,
            ControlAuthoredAuthority(
                authoritativeClientID: authority.authoritativeClientID,
                grantID: authority.grantID,
                grantInvocationNamespace: authority.grantInvocationNamespace
            ),
            invocationID,
            expectedRevision,
            reason,
            Self.idempotencyKey(idempotencyKey)
        ))
    }

    public func staleAuthoredAuthority(namespace: String) async throws {
        let response = try request(.staleMCPAuthority(namespace: namespace))
        guard case .acknowledged = response else { return try unexpected(response, for: "staleMCPAuthority") }
    }

    private func mutation(_ controlRequest: ControlRequest) throws -> JSONValue {
        let response = try request(controlRequest)
        guard case let .mutation(result) = response else { return try unexpected(response, for: "mutation") }
        return try Self.encode(result)
    }

    private func authored(_ controlRequest: ControlRequest) throws -> JSONValue {
        let response = try request(controlRequest)
        guard case let .authored(result) = response else { return try unexpected(response, for: "authored mutation") }
        return try Self.encode(result)
    }

    private func request(_ controlRequest: ControlRequest) throws -> ControlResponse {
        try writeAll(JSONEncoder().encode(controlRequest) + Data("\n".utf8))
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                var line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                guard !line.isEmpty else { continue }
                let response = try JSONDecoder().decode(ControlResponse.self, from: line)
                if case let .failure(error) = response { throw AppControlSocketError.remoteError(error) }
                return response
            }
            guard readBuffer.count <= Self.maximumResponseBytes else {
                throw AppControlSocketError.responseTooLarge
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 {
                readBuffer.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                throw AppControlSocketError.disconnected
            } else if errno != EINTR {
                throw AppControlSocketError.readFailed(errno)
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.send(descriptor, base.advanced(by: written), rawBuffer.count - written, 0)
                if count > 0 {
                    written += count
                } else if count < 0, errno != EINTR {
                    throw AppControlSocketError.writeFailed(errno)
                }
            }
        }
    }

    private func unexpected<T>(_ response: ControlResponse, for operation: String) throws -> T {
        throw AppControlSocketError.malformedResponse("unexpected \(response) for \(operation)")
    }

    private static func idempotencyKey(_ key: MCPMutationKey) -> IdempotencyKey {
        IdempotencyKey("\(key.clientID)|\(key.grantNamespace)|\(key.invocationID)")
    }

    private static func controlKey(named name: String) throws -> ControlKey {
        switch name.lowercased() {
        case "up": return .up
        case "down": return .down
        case "right": return .right
        case "left": return .left
        case "home": return .home
        case "end": return .end
        case "insert": return .insert
        case "delete": return .delete
        case "pageup", "page_up": return .pageUp
        case "pagedown", "page_down": return .pageDown
        case "enter", "return": return .enter
        case "tab": return .tab
        case "backtab", "shift_tab": return .backtab
        case "escape", "esc": return .escape
        case "backspace": return .backspace
        default:
            if name.count == 1 { return .character(name) }
            if name.lowercased().hasPrefix("f"), let number = Int(name.dropFirst()), (1...24).contains(number) {
                return .function(number)
            }
            throw MCPToolError.invalidArguments("Unsupported key name: \(name)")
        }
    }

    private static func target(_ target: Target) -> JSONValue {
        var value: [String: JSONValue] = [
            "room_id": .string(target.room.rawValue.uuidString.lowercased())
        ]
        if let session = target.session { value["session_id"] = .string(session.rawValue.uuidString.lowercased()) }
        if let pane = target.pane { value["pane_id"] = .string(pane.rawValue.uuidString.lowercased()) }
        return .object(value)
    }

    private static func bounded(_ result: RunCommandResult, maximumBytes: Int) -> RunCommandResult {
        guard case let .completed(outcome, receipt) = result else { return result }
        let bounded = CommandOutcome(
            pane: outcome.pane,
            command: outcome.command,
            exitCode: outcome.exitCode,
            output: boundedOutput(outcome.output, maximumBytes: maximumBytes),
            region: outcome.region
        )
        return .completed(bounded, receipt)
    }

    private static func boundedOutput(_ lines: [String], maximumBytes: Int) -> [String] {
        var remaining = maximumBytes
        var result: [String] = []
        for line in lines {
            guard remaining > 0 else { break }
            let bytes = Array(line.utf8)
            if bytes.count <= remaining {
                result.append(line)
                remaining -= bytes.count
            } else {
                var used = 0
                var end = line.startIndex
                while end < line.endIndex {
                    let next = line.index(after: end)
                    let count = line[end..<next].utf8.count
                    guard used + count <= remaining else { break }
                    used += count
                    end = next
                }
                result.append(String(line[..<end]))
                break
            }
        }
        return result
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

private extension MCPPaneDestination {
    var remoteDestination: RemoteDestination {
        RemoteDestination(
            kind: kind == .localShell ? .localShell : .ssh,
            host: host.map(HostAlias.init(rawValue:)),
            command: command,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
}
