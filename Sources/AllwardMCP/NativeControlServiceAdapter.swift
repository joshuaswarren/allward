import AllwardControl
import AllwardCore
import AllwardRemote
import AllwardSurfaces
import AllwardTerminal
import Foundation

public struct NativeControlServiceAdapter: AllwardControlFacade, Sendable {
    private let control: ControlService

    public init(control: ControlService) {
        self.control = control
    }

    public func listPanes(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let snapshot = await control.listPanes()
        let windowByPane = snapshot.windows.reduce(into: [PaneID: WindowID]()) { result, window in
            for pane in window.tabs.flatMap({ $0.tree?.leaves ?? [] }) {
                result[pane] = window.id
            }
        }
        let panes = try snapshot.panes.filter { scope.allows($0.target) }.map { pane in
            guard let windowID = windowByPane[pane.id] else {
                throw MCPToolError.capabilityUnavailable("The pane is not attached to a receiver-owned window")
            }
            return JSONValue.object([
                "pane_id": .string(pane.id.rawValue.uuidString.lowercased()),
                "session_id": .string(pane.session.rawValue.uuidString.lowercased()),
                "window_id": .string(windowID.rawValue.uuidString.lowercased()),
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

    public func screen(target: Target) async throws -> JSONValue {
        guard let screen = await control.readScreen(target: target) else {
            throw MCPToolError.capabilityUnavailable("The pane no longer exists")
        }
        var result: [String: JSONValue] = [
            "pane_id": .string(screen.pane.rawValue.uuidString.lowercased()),
            "generation": .integer(Int64(screen.generation.rawValue)),
            "lines": .array(screen.lines.map(JSONValue.string)),
            "cursor": try Self.encode(screen.cursor)
        ]
        if let title = screen.title { result["title"] = .string(title) }
        return .object(result)
    }

    public func history(target: Target, lines: Int) async throws -> JSONValue {
        let pane = try Self.pane(from: target)
        guard let history = await control.readHistory(target: target, lines: lines) else {
            throw MCPToolError.capabilityUnavailable("The pane no longer exists")
        }
        return .object(["pane_id": .string(pane.rawValue.uuidString.lowercased()),
                        "lines": .array(history.map(JSONValue.string))])
    }

    public func sendText(
        target: Target, generation: Generation, text: String, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.sendText(
            to: target,
            generation: generation,
            text: text,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func sendKeys(
        target: Target, generation: Generation, keys: [String], idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.sendKeys(
            to: target,
            generation: generation,
            keys: try keys.map(Self.terminalKey),
            idempotencyKey: Self.controlKey(idempotencyKey)
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
        let result = await control.runCommand(
            target: target,
            generation: generation,
            command: command,
            bound: attemptBound,
            idempotencyKey: Self.controlKey(idempotencyKey)
        )
        switch result {
        case let .completed(outcome, receipt):
            let bounded = CommandOutcome(
                pane: outcome.pane,
                command: outcome.command,
                exitCode: outcome.exitCode,
                output: Self.boundedOutput(outcome.output, maximumBytes: bound.maximumOutputBytes),
                region: outcome.region
            )
            return try Self.encode(RunCommandResult.completed(bounded, receipt))
        case .rejected:
            return try Self.encode(result)
        }
    }

    public func recoverCommandReceipt(idempotencyKey: MCPMutationKey) async throws -> JSONValue? {
        guard let receipt = await control.recoverCommandReceipt(Self.controlKey(idempotencyKey)) else { return nil }
        return try Self.encode(receipt)
    }

    public func lastCommand(target: Target) async throws -> JSONValue {
        guard let command = await control.lastCommand(target: target) else { return .null }
        return try Self.encode(command)
    }

    public func exitCode(target: Target) async throws -> JSONValue {
        guard let code = await control.exitCode(target: target) else { return .null }
        return .integer(Int64(code))
    }

    public func splitPane(
        target: Target,
        generation: Generation,
        destination: MCPPaneDestination,
        orientation: String,
        ratio: Double,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        let remote: RemoteDestination
        switch destination.kind {
        case .localShell:
            remote = RemoteDestination.localShell(
                workingDirectory: destination.workingDirectory,
                environment: destination.environment
            )
        case .ssh:
            guard let host = destination.host else {
                throw MCPToolError.invalidArguments("destination.host is required for ssh")
            }
            remote = RemoteDestination.ssh(
                HostAlias(rawValue: host),
                command: destination.command,
                environment: destination.environment
            )
        }
        guard let splitOrientation = SplitOrientation(rawValue: orientation) else {
            throw MCPToolError.invalidArguments("orientation must be horizontal or vertical")
        }
        return try Self.encode(await control.splitPane(
            target: target,
            generation: generation,
            destination: remote,
            orientation: splitOrientation,
            ratio: ratio,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func createTab(
        room: RoomID, window: WindowID, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.createTab(
            target: Target(room: room),
            generation: generation,
            window: window,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func closePane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.closePane(
            target: target,
            generation: generation,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func focusPane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.focusPane(
            target: target,
            generation: generation,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func boardSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let snapshot = await control.boardSnapshot()
        let groups = snapshot.groups.compactMap { group -> BoardGroup? in
            let rows = group.rows.filter { scope.allows($0.target) }
            guard !rows.isEmpty else { return nil }
            return BoardGroup(roomID: group.roomID, host: group.host, workspace: group.workspace, rows: rows)
        }
        let visibleCount = groups.reduce(0) { $0 + $1.rows.count }
        let scoped = BoardSnapshot(
            state: groups.isEmpty ? .emptyNoOpenLoops : .populated,
            groups: groups,
            visibleRowCount: visibleCount,
            exactTotal: visibleCount,
            generation: snapshot.generation
        )
        return try Self.encode(scoped)
    }

    public func routerSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let snapshot = await control.routerSnapshot()
        let items = snapshot.items.filter { scope.allows($0.target) }
        let highest = items.map(\.attentionClass).min()
        let scoped = RouterSnapshot(
            state: highest.map(RouterState.active) ?? .noActionableItems,
            highestPriorityClass: highest,
            totalActionableCount: items.filter(\.isActionable).count,
            filteredCount: 0,
            roomID: nil,
            freshness: items.first?.freshness,
            destinationKey: items.first?.destinationKey,
            items: items,
            newEpochs: snapshot.newEpochs.filter { id in items.contains(where: { $0.id == id }) },
            generation: snapshot.generation
        )
        return try Self.encode(scoped)
    }

    public func listRooms(scope: MCPGrantTargetScope) async throws -> JSONValue {
        let rooms = await control.listRooms().filter { scope.allows(room: $0.id) }
        return .object(["rooms": .array(try rooms.map(Self.encode))])
    }

    public func setRoom(
        window: WindowID,
        room: RoomID,
        sourceTarget: Target,
        generation: Generation,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.setRoom(
            window: window,
            room: room,
            target: sourceTarget,
            generation: generation,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func teleport(
        target: Target, generation: Generation, destination: PaneID, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.teleport(
            target: target,
            generation: generation,
            to: TeleportDestination(pane: destination),
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func createAuthoredRecord(
        logicalKey: String,
        content: AllwardSurfaces.MCPAuthoredContent,
        target: Target,
        generation: Generation,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.createAuthoredRecord(
            target: target,
            generation: generation,
            callerLogicalKey: logicalKey,
            content: content,
            authority: authority,
            invocationID: invocationID,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func updateAuthoredRecord(
        logicalKey: String,
        content: AllwardSurfaces.MCPAuthoredContent,
        target: Target,
        generation: Generation,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.updateAuthoredRecord(
            target: target,
            generation: generation,
            callerLogicalKey: logicalKey,
            content: content,
            authority: authority,
            invocationID: invocationID,
            expectedRevision: expectedRevision,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func endAuthoredRecord(
        logicalKey: String,
        target: Target,
        generation: Generation,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue {
        try Self.encode(await control.endAuthoredRecord(
            target: target,
            generation: generation,
            callerLogicalKey: logicalKey,
            authority: authority,
            invocationID: invocationID,
            expectedRevision: expectedRevision,

            reason: reason,
            idempotencyKey: Self.controlKey(idempotencyKey)
        ))
    }

    public func staleAuthoredAuthority(namespace: String) async throws {
        await control.staleMCPAuthority(namespace: namespace)
    }

    private static func pane(from target: Target) throws -> PaneID {
        guard let pane = target.pane else { throw MCPToolError.invalidArguments("target.pane_id is required") }
        return pane
    }

    private static func controlKey(_ key: MCPMutationKey) -> IdempotencyKey {
        IdempotencyKey("\(key.clientID)|\(key.grantNamespace)|\(key.invocationID)")
    }

    private static func terminalKey(_ name: String) throws -> TerminalKey {
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

    private static func boundedOutput(_ lines: [String], maximumBytes: Int) -> [String] {
        var remaining = maximumBytes
        var result: [String] = []
        for line in lines {
            guard remaining > 0 else { break }
            let byteCount = line.utf8.count
            if byteCount <= remaining {
                result.append(line)
                remaining -= byteCount
            } else {
                var end = line.startIndex
                var used = 0
                while end < line.endIndex {
                    let next = line.index(after: end)
                    let characterBytes = line[end..<next].utf8.count
                    guard used + characterBytes <= remaining else { break }
                    used += characterBytes
                    end = next
                }
                result.append(String(line[..<end]))
                remaining = 0
            }
        }
        return result
    }

    private static func target(_ target: Target) -> JSONValue {
        var result: [String: JSONValue] = [
            "room_id": .string(target.room.rawValue.uuidString.lowercased())
        ]
        if let session = target.session {
            result["session_id"] = .string(session.rawValue.uuidString.lowercased())
        }
        if let pane = target.pane {
            result["pane_id"] = .string(pane.rawValue.uuidString.lowercased())
        }
        return .object(result)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
