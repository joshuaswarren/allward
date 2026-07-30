import AllwardControl
import AllwardCore
import AllwardSurfaces
import Foundation

public struct MCPRunBound: Codable, Hashable, Sendable {
    public var timeoutMilliseconds: Int
    public var maximumOutputBytes: Int

    public init(timeoutMilliseconds: Int = 120_000, maximumOutputBytes: Int = 1_048_576) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct MCPPaneDestination: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case localShell = "local_shell"
        case ssh
    }

    public var kind: Kind
    public var host: String?
    public var command: [String]?
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        kind: Kind,
        host: String? = nil,
        command: [String]? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.kind = kind
        self.host = host
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public protocol AllwardControlFacade: Sendable {
    func listPanes(scope: MCPGrantTargetScope) async throws -> JSONValue
    func screen(target: Target) async throws -> JSONValue
    func history(target: Target, lines: Int) async throws -> JSONValue
    func sendText(
        target: Target, generation: Generation, text: String,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func sendKeys(
        target: Target, generation: Generation, keys: [String],
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func runCommand(
        target: Target, generation: Generation, command: String, bound: MCPRunBound,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func recoverCommandReceipt(idempotencyKey: MCPMutationKey) async throws -> JSONValue?
    func lastCommand(target: Target) async throws -> JSONValue
    func exitCode(target: Target) async throws -> JSONValue
    func splitPane(
        target: Target, generation: Generation, destination: MCPPaneDestination,
        orientation: String, ratio: Double, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func createTab(
        room: RoomID, window: WindowID, generation: Generation,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func closePane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func focusPane(
        target: Target, generation: Generation, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func boardSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue
    func routerSnapshot(scope: MCPGrantTargetScope) async throws -> JSONValue
    func listRooms(scope: MCPGrantTargetScope) async throws -> JSONValue
    func setRoom(
        window: WindowID,
        room: RoomID,
        sourceTarget: Target,
        generation: Generation,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func teleport(
        target: Target, generation: Generation, destination: PaneID,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func createAuthoredRecord(
        logicalKey: String, content: AllwardSurfaces.MCPAuthoredContent, target: Target,
        generation: Generation, authority: AllwardSurfaces.MCPAuthoredAuthority, invocationID: UUID,
        idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func updateAuthoredRecord(
        logicalKey: String, content: AllwardSurfaces.MCPAuthoredContent, target: Target,
        generation: Generation, authority: AllwardSurfaces.MCPAuthoredAuthority, invocationID: UUID,
        expectedRevision: UInt64, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func endAuthoredRecord(
        logicalKey: String, target: Target, generation: Generation,
        authority: AllwardSurfaces.MCPAuthoredAuthority, invocationID: UUID,
        expectedRevision: UInt64, reason: String, idempotencyKey: MCPMutationKey
    ) async throws -> JSONValue
    func staleAuthoredAuthority(namespace: String) async throws
}

public struct MCPToolDefinition: Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue, annotations: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

public protocol MCPToolProviding: Sendable {
    func listTools() async -> [MCPToolDefinition]
    func callTool(name: String, arguments: JSONValue, context: MCPProtocolClientContext) async throws -> JSONValue
}

public enum MCPToolError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownTool(String)
    case invalidArguments(String)
    case capabilityUnavailable(String)

    public var description: String {
        switch self {
        case let .unknownTool(name): "Unknown tool: \(name)"
        case let .invalidArguments(message): "Invalid tool arguments: \(message)"
        case let .capabilityUnavailable(message): "Capability unavailable: \(message)"
        }
    }
}

public actor AllwardTools: MCPToolProviding {
    private let control: any AllwardControlFacade
    private let authorizer: CallerCapabilityAuthorizer
    private let ledger: MCPMutationLedger

    public init(
        control: any AllwardControlFacade,
        authorizer: CallerCapabilityAuthorizer,
        ledger: MCPMutationLedger
    ) {
        self.control = control
        self.authorizer = authorizer
        self.ledger = ledger
    }

    public func listTools() -> [MCPToolDefinition] { Self.definitions }

    public func callTool(
        name: String,
        arguments: JSONValue,
        context: MCPProtocolClientContext
    ) async throws -> JSONValue {
        do {
            try await authorizer.validateConnection(assertedClientID: context.assertedClientID)
        } catch let error as MCPAuthorizationError {
            switch error {
            case .expiredGrant, .revokedGrant, .retiredGrant:
                try await control.staleAuthoredAuthority(
                    namespace: await authorizer.authoredAuthorityNamespace()
                )
            default:
                break
            }
            throw error
        }
        try Self.validateArgumentKeys(for: name, arguments: arguments)
        let input = try ToolArguments(arguments)
        switch name {
        case "allward_list_panes":
            let validated = try await authorizer.validate(capability: .listPanes)
            return try await control.listPanes(scope: validated.targetScope)
        case "allward_screen":
            let target = try input.target()
            _ = try await authorizer.validate(capability: .readScreen, target: target)
            return try await control.screen(target: target)
        case "allward_history":
            let target = try input.target()
            _ = try await authorizer.validate(capability: .readHistory, target: target)
            return try await control.history(target: target, lines: try input.int("lines", range: 1...100_000))
        case "allward_send_text":
            return try await mutate(name, input: input, capability: .sendText) { target, generation, key in
                try await self.control.sendText(
                    target: target, generation: generation, text: try input.string("text"), idempotencyKey: key
                )
            }
        case "allward_send_keys":
            return try await mutate(name, input: input, capability: .sendKeys) { target, generation, key in
                try await self.control.sendKeys(
                    target: target, generation: generation, keys: try input.strings("keys"), idempotencyKey: key
                )
            }
        case "allward_run":
            return try await mutate(
                name,
                input: input,
                capability: .runCommand,
                marksCompleted: true,
                recovery: { try await self.control.recoverCommandReceipt(idempotencyKey: $0) }
            ) { target, generation, key in
                let bound = MCPRunBound(
                    timeoutMilliseconds: try input.optionalInt(
                        "timeout_ms", default: 120_000, range: 1...3_600_000
                    ),
                    maximumOutputBytes: try input.optionalInt(
                        "maximum_output_bytes", default: 1_048_576, range: 1...8_388_608
                    )
                )
                let result = try await self.control.runCommand(
                    target: target,
                    generation: generation,
                    command: try input.string("command"),
                    bound: bound,
                    idempotencyKey: key
                )
                return result
            }
        case "allward_last_command":
            let target = try input.target()
            _ = try await authorizer.validate(capability: .readLastCommand, target: target)
            return try await control.lastCommand(target: target)
        case "allward_exit_code":
            let target = try input.target()
            _ = try await authorizer.validate(capability: .readExitCode, target: target)
            return try await control.exitCode(target: target)
        case "allward_split":
            return try await mutate(name, input: input, capability: .splitPane) { target, generation, key in
                try await self.control.splitPane(
                    target: target,
                    generation: generation,
                    destination: try input.paneDestination(),
                    orientation: try input.enumString("orientation", allowed: ["horizontal", "vertical"]),
                    ratio: try input.double("ratio", range: 0.1...0.9),
                    idempotencyKey: key
                )
            }
        case "allward_new_tab":
            let room = try input.roomID()
            let window = try input.windowID()
            let invocation = try input.invocationID()
            let validated = try await authorizer.validate(
                capability: .createTab, room: room, invocationID: invocation.uuidString, mutation: true
            )
            _ = try await validateWindowScope(window, scope: validated.targetScope)
            let key = Self.mutationKey(validated, invocation: invocation)
            return try await ledger.perform(
                key: key,
                descriptor: try input.descriptor(
                    operation: name,
                    exactTarget: "room:\(room.rawValue.uuidString.lowercased())/window:\(try input.string("window_id"))"
                )
            ) {
                try await self.control.createTab(
                    room: room,
                    window: window,
                    generation: try input.generation(),
                    idempotencyKey: key
                )
            }
        case "allward_close_pane":
            return try await mutate(name, input: input, capability: .closePane) { target, generation, key in
                try await self.control.closePane(target: target, generation: generation, idempotencyKey: key)
            }
        case "allward_focus":
            return try await mutate(name, input: input, capability: .focusPane) { target, generation, key in
                try await self.control.focusPane(target: target, generation: generation, idempotencyKey: key)
            }
        case "allward_board":
            let validated = try await authorizer.validate(capability: .readBoard)
            return try await control.boardSnapshot(scope: validated.targetScope)
        case "allward_router":
            let validated = try await authorizer.validate(capability: .readRouter)
            return try await control.routerSnapshot(scope: validated.targetScope)
        case "allward_rooms":
            let validated = try await authorizer.validate(capability: .listRooms)
            return try await control.listRooms(scope: validated.targetScope)
        case "allward_set_room":
            let room = try input.roomID()
            let window = try input.windowID()
            let invocation = try input.invocationID()
            let validated = try await authorizer.validate(
                capability: .setRoom, room: room, invocationID: invocation.uuidString, mutation: true
            )
            let sourceTarget = try await validateWindowScope(window, scope: validated.targetScope)
            let key = Self.mutationKey(validated, invocation: invocation)
            return try await ledger.perform(
                key: key,
                descriptor: try input.descriptor(
                    operation: name,
                    exactTarget: "room:\(room.rawValue.uuidString.lowercased())/window:\(try input.string("window_id"))"
                )
            ) {
                try await self.control.setRoom(
                    window: window,
                    room: room,
                    sourceTarget: sourceTarget,
                    generation: try input.generation(),
                    idempotencyKey: key
                )
            }
        case "allward_teleport":
            let destination = PaneID(rawValue: try input.uuid("destination"))
            try await authorizer.validateScopedPane(destination)
            return try await mutate(name, input: input, capability: .teleport) { target, generation, key in
                try await self.control.teleport(
                    target: target,
                    generation: generation,
                    destination: destination,
                    idempotencyKey: key
                )
            }
        case "allward_create_record":
            return try await recordMutation(name, input: input, capability: .createRecord, expectedRevision: nil)
        case "allward_update_record":
            return try await recordMutation(
                name,
                input: input,
                capability: .updateRecord,
                expectedRevision: try input.uint64("expected_revision")
            )
        case "allward_end_record":
            return try await endRecord(name, input: input)
        default:
            throw MCPToolError.unknownTool(name)
        }
    }

    private func mutate(
        _ operation: String,
        input: ToolArguments,
        capability: MCPToolCapability,
        marksCompleted: Bool = false,
        recovery: (@Sendable (MCPMutationKey) async throws -> JSONValue?)? = nil,
        dispatch: @escaping @Sendable (Target, Generation, MCPMutationKey) async throws -> JSONValue
    ) async throws -> JSONValue {
        let target = try input.target()
        let generation = try input.generation()
        let invocation = try input.invocationID()
        let validated = try await authorizer.validate(
            capability: capability,
            target: target,
            invocationID: invocation.uuidString,
            mutation: true
        )
        let key = Self.mutationKey(validated, invocation: invocation)
        do {
            let result = try await ledger.perform(
                key: key,
                descriptor: try input.descriptor(operation: operation, exactTarget: Self.exactTarget(target))
            ) {
                try await dispatch(target, generation, key)
            }
            if marksCompleted {
                try await ledger.markCompleted(key: key, result: result)
            }
            return result
        } catch MCPMutationLedgerError.outcomeUnknown {
            guard let recovery, let value = try await recovery(key) else {
                throw MCPMutationLedgerError.outcomeUnknown
            }
            let data = try JSONEncoder().encode(value)
            let receipt = try JSONDecoder().decode(CommandExecutionReceipt.self, from: data)
            switch receipt.status {
            case .committed, .final, .error:
                try await ledger.resolveOutcomeUnknown(key: key, result: value)
                return value
            case .cancelled:
                try await ledger.markCancelledBeforeCommit(key: key)
                throw MCPMutationLedgerError.cancelledBeforeCommit
            case .accepted, .outcomeUnknown:
                throw MCPMutationLedgerError.outcomeUnknown
            }
        }
    }

    private func recordMutation(
        _ operation: String,
        input: ToolArguments,
        capability: MCPToolCapability,
        expectedRevision: UInt64?
    ) async throws -> JSONValue {
        let target = try input.target()
        let generation = try input.generation()
        let invocation = try input.invocationID()
        let validated = try await authorizer.validate(
            capability: capability,
            target: target,
            invocationID: invocation.uuidString,
            mutation: true
        )
        let key = Self.mutationKey(validated, invocation: invocation)
        let authority = AllwardSurfaces.MCPAuthoredAuthority(
            authoritativeClientID: validated.clientID,
            grantID: validated.grantID.uuidString,
            grantInvocationNamespace: validated.grantNamespace
        )
        let content = try input.recordContent()
        let logicalKey = try input.string("logical_key")
        try MCPAuthoredRecordLifecycle.validate(logicalKey: logicalKey, content: content)
        return try await ledger.perform(
            key: key,
            descriptor: try input.descriptor(operation: operation, exactTarget: Self.exactTarget(target))
        ) {
            if let expectedRevision {
                return try await self.control.updateAuthoredRecord(
                    logicalKey: logicalKey,
                    content: content,
                    target: target,
                    generation: generation,
                    authority: authority,
                    invocationID: invocation,
                    expectedRevision: expectedRevision,
                    idempotencyKey: key
                )
            }
            return try await self.control.createAuthoredRecord(
                logicalKey: logicalKey,
                content: content,
                target: target,
                generation: generation,
                authority: authority,
                invocationID: invocation,
                idempotencyKey: key
            )
        }
    }

    private func endRecord(_ operation: String, input: ToolArguments) async throws -> JSONValue {
        let target = try input.target()
        let generation = try input.generation()
        let invocation = try input.invocationID()
        let validated = try await authorizer.validate(
            capability: .endRecord,
            target: target,
            invocationID: invocation.uuidString,
            mutation: true
        )
        let key = Self.mutationKey(validated, invocation: invocation)
        let authority = AllwardSurfaces.MCPAuthoredAuthority(
            authoritativeClientID: validated.clientID,
            grantID: validated.grantID.uuidString,
            grantInvocationNamespace: validated.grantNamespace
        )
        let logicalKey = try input.string("logical_key")
        try MCPAuthoredRecordLifecycle.validate(logicalKey: logicalKey)
        return try await ledger.perform(
            key: key,
            descriptor: try input.descriptor(operation: operation, exactTarget: Self.exactTarget(target))
        ) {
            try await self.control.endAuthoredRecord(
                logicalKey: logicalKey,
                target: target,
                generation: generation,
                authority: authority,
                invocationID: invocation,
                expectedRevision: try input.uint64("expected_revision"),
                reason: try input.string("reason"),
                idempotencyKey: key
            )
        }
    }

    private static func validateArgumentKeys(for name: String, arguments: JSONValue) throws {
        guard let definition = definitions.first(where: { $0.name == name }) else {
            throw MCPToolError.unknownTool(name)
        }
        try validateArgumentKeys(arguments, schema: definition.inputSchema, path: "arguments")
    }

    private static func validateArgumentKeys(_ value: JSONValue, schema: JSONValue, path: String) throws {
        if case let .object(values) = value, schema.objectValue?["type"] == .string("object") {
            let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
            if schema.objectValue?["additionalProperties"] == .bool(false) {
                let extras = Set(values.keys).subtracting(properties.keys).sorted()
                guard extras.isEmpty else {
                    throw MCPToolError.invalidArguments(
                        "Unsupported \(path) fields: \(extras.joined(separator: ", "))"
                    )
                }
            }
            for (key, child) in values {
                if let childSchema = properties[key] {
                    try validateArgumentKeys(child, schema: childSchema, path: "\(path).\(key)")
                }
            }
        }
        if case let .array(values) = value, let itemSchema = schema.objectValue?["items"] {
            for (index, child) in values.enumerated() {
                try validateArgumentKeys(child, schema: itemSchema, path: "\(path)[\(index)]")
            }
        }
    }

    private func validateWindowScope(_ window: WindowID, scope: MCPGrantTargetScope) async throws -> Target {
        let result = try await control.listPanes(scope: scope)
        let expectedID = window.rawValue.uuidString.lowercased()
        guard
            case let .array(panes) = result.objectValue?["panes"],
            let pane = panes.first(where: { $0.objectValue?["window_id"]?.stringValue == expectedID }),
            let target = pane.objectValue?["target"]
        else {
            throw MCPAuthorizationError.windowOutOfScope(window)
        }
        return try ToolArguments(.object(["target": target])).target()
    }

    private static func exactTarget(_ target: Target) -> String {
        var parts = ["room:\(target.room.rawValue.uuidString.lowercased())"]
        if let session = target.session {
            parts.append("session:\(session.rawValue.uuidString.lowercased())")
        }
        if let pane = target.pane {
            parts.append("pane:\(pane.rawValue.uuidString.lowercased())")
        }
        return parts.joined(separator: "/")
    }

    private static func mutationKey(_ context: MCPCallContext, invocation: UUID) -> MCPMutationKey {
        MCPMutationKey(
            clientID: context.clientID,
            grantNamespace: context.grantNamespace,
            invocationID: invocation.uuidString.lowercased()
        )
    }

    public static let definitions: [MCPToolDefinition] = ToolSchemas.all
}

private struct ToolArguments: Sendable {
    let values: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard case let .object(values) = value else {
            throw MCPToolError.invalidArguments("arguments must be a JSON object")
        }
        self.values = values
    }

    func string(_ name: String) throws -> String {
        guard let value = values[name]?.stringValue, !value.isEmpty else {
            throw MCPToolError.invalidArguments("\(name) must be a non-empty string")
        }
        return value
    }

    func strings(_ name: String) throws -> [String] {
        guard case let .array(values)? = values[name] else {
            throw MCPToolError.invalidArguments("\(name) must be an array of strings")
        }
        let strings = try values.map { value -> String in
            guard let string = value.stringValue, !string.isEmpty else {
                throw MCPToolError.invalidArguments("\(name) must contain only non-empty strings")
            }
            return string
        }
        guard !strings.isEmpty else { throw MCPToolError.invalidArguments("\(name) must not be empty") }
        return strings
    }

    func int(_ name: String, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[name]?.integerValue, let value = Int(exactly: raw), range.contains(value) else {
            let message = "\(name) must be an integer from \(range.lowerBound) to \(range.upperBound)"
            throw MCPToolError.invalidArguments(message)
        }
        return value
    }

    func optionalInt(_ name: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard values[name] != nil else { return defaultValue }
        return try int(name, range: range)
    }

    func uint64(_ name: String) throws -> UInt64 {
        guard let raw = values[name]?.integerValue, let value = UInt64(exactly: raw) else {
            throw MCPToolError.invalidArguments("\(name) must be a non-negative integer")
        }
        return value
    }

    func double(_ name: String, range: ClosedRange<Double>) throws -> Double {
        let value: Double?
        switch values[name] {
        case let .number(number): value = number
        case let .integer(integer): value = Double(integer)
        default: value = nil
        }
        guard let value, value.isFinite, range.contains(value) else {
            let message = "\(name) must be a number from \(range.lowerBound) to \(range.upperBound)"
            throw MCPToolError.invalidArguments(message)
        }
        return value
    }

    func enumString(_ name: String, allowed: Set<String>) throws -> String {
        let value = try string(name)
        guard allowed.contains(value) else {
            throw MCPToolError.invalidArguments("\(name) must be one of \(allowed.sorted().joined(separator: ", "))")
        }
        return value
    }

    func uuid(_ name: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(name)) else {
            throw MCPToolError.invalidArguments("\(name) must be a UUID")
        }
        return value
    }

    func target() throws -> Target {
        guard case let .object(target)? = values["target"] else {
            throw MCPToolError.invalidArguments("target must be an object")
        }
        guard let roomText = target["room_id"]?.stringValue, let room = UUID(uuidString: roomText) else {
            throw MCPToolError.invalidArguments("target.room_id must be a UUID")
        }
        let session: SessionID?
        if let value = target["session_id"]?.stringValue {
            guard let id = UUID(uuidString: value) else {
                throw MCPToolError.invalidArguments("target.session_id must be a UUID")
            }
            session = SessionID(rawValue: id)
        } else {
            session = nil
        }
        let pane: PaneID?
        if let value = target["pane_id"]?.stringValue {
            guard let id = UUID(uuidString: value) else {
                throw MCPToolError.invalidArguments("target.pane_id must be a UUID")
            }
            pane = PaneID(rawValue: id)
        } else {
            pane = nil
        }
        return Target(room: RoomID(rawValue: room), session: session, pane: pane)
    }

    func roomID() throws -> RoomID { RoomID(rawValue: try uuid("room_id")) }
    func windowID() throws -> WindowID { WindowID(rawValue: try uuid("window_id")) }
    func invocationID() throws -> UUID { try uuid("invocation_id") }
    func generation() throws -> Generation { Generation(rawValue: try uint64("generation")) }

    func paneDestination() throws -> MCPPaneDestination {
        guard case let .object(destination)? = values["destination"],
              let kindText = destination["kind"]?.stringValue,
              let kind = MCPPaneDestination.Kind(rawValue: kindText)
        else {
            throw MCPToolError.invalidArguments("destination must contain kind local_shell or ssh")
        }
        let host = destination["host"]?.stringValue
        if kind == .ssh, host?.isEmpty != false {
            throw MCPToolError.invalidArguments("destination.host is required for ssh")
        }
        let command: [String]?
        if case let .array(items)? = destination["command"] {
            command = try items.map { item in
                guard let value = item.stringValue, !value.isEmpty else {
                    throw MCPToolError.invalidArguments("destination.command must contain non-empty strings")
                }
                return value
            }
        } else {
            command = nil
        }
        var environment: [String: String] = [:]
        if case let .object(entries)? = destination["environment"] {
            for (name, value) in entries {
                guard let text = value.stringValue else {
                    throw MCPToolError.invalidArguments("destination.environment values must be strings")
                }
                environment[name] = text
            }
        }
        return MCPPaneDestination(
            kind: kind,
            host: host,
            command: command,
            workingDirectory: destination["working_directory"]?.stringValue,
            environment: environment
        )
    }

    func recordContent() throws -> AllwardSurfaces.MCPAuthoredContent {
        guard let kind = NormalizedRecord.Kind(rawValue: try string("kind")) else {
            throw MCPToolError.invalidArguments("kind is not a normalized record kind")
        }
        return AllwardSurfaces.MCPAuthoredContent(
            kind: kind,
            title: try string("title"),
            detail: values["detail"]?.stringValue,
            agentState: values["agent_state"]?.stringValue
        )
    }

    func descriptor(operation: String, exactTarget: String) throws -> MCPMutationDescriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(JSONValue.object(values))
        guard let canonical = String(data: encoded, encoding: .utf8) else {
            throw MCPToolError.invalidArguments("arguments are not valid UTF-8 JSON")
        }
        return MCPMutationDescriptor(
            operation: operation,
            canonicalArguments: canonical,
            exactTarget: exactTarget
        )
    }
}

private enum ToolSchemas {
    static let target: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "room_id": uuid("Receiver-issued Room identifier"),
            "session_id": uuid("Receiver-issued session identifier"),
            "pane_id": uuid("Receiver-issued pane identifier")
        ]),
        "required": .array([.string("room_id")])
    ])

    static let destination: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "kind": enumeration("Pane connection kind", ["local_shell", "ssh"]),
            "host": string("Configured host alias for ssh", minLength: 1),
            "command": .object([
                "type": .string("array"),
                "items": string("Command argument", minLength: 1)
            ]),
            "working_directory": string("Initial working directory"),
            "environment": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")])
            ])
        ]),
        "required": .array([.string("kind")])
    ])

    static let all: [MCPToolDefinition] = [
        tool("allward_list_panes", "List panes in the caller's grant scope.", schema([:] , []), readOnly: true),
        tool("allward_screen", "Read the current visible screen for one pane.", targetSchema(), readOnly: true),
        tool("allward_history", "Read bounded terminal history for one pane.", schema([
            "target": target, "lines": integer("Maximum logical lines", 1, 100_000)
        ], ["target", "lines"]), readOnly: true),
        tool("allward_send_text", "Send UTF-8 text to one exact pane generation.", mutationSchema([
            "text": string("Text to send", minLength: 1)
        ]), readOnly: false),
        tool("allward_send_keys", "Send named keys to one exact pane generation.", mutationSchema([
            "keys": .object([
                "type": .string("array"),
                "minItems": .integer(1),
                "items": string("Key name", minLength: 1)
            ])
        ]), readOnly: false),
        tool("allward_run", "Run one command and wait for its owned OSC 133 completion marker.", mutationSchema([
            "command": string("Command to run", minLength: 1),
            "timeout_ms": integer("Completion timeout in milliseconds", 1, 3_600_000),
            "maximum_output_bytes": integer("Maximum returned output bytes", 1, 8_388_608)
        ], optional: ["timeout_ms", "maximum_output_bytes"]), readOnly: false),
        tool(
            "allward_last_command",
            "Read the last proven command region for one pane.",
            targetSchema(),
            readOnly: true
        ),
        tool(
            "allward_exit_code",
            "Read the exit code from the last proven completed command.",
            targetSchema(),
            readOnly: true
        ),
        tool("allward_split", "Split one pane in the Allward-owned layout.", mutationSchema([
            "destination": destination,
            "orientation": enumeration("Split orientation", ["horizontal", "vertical"]),
            "ratio": number("Leading child ratio", 0.1, 0.9)
        ]), readOnly: false),
        tool("allward_new_tab", "Create a tab in one window and Room.", windowMutationSchema(), readOnly: false),
        tool("allward_close_pane", "Close one exact pane generation.", mutationSchema([:]), readOnly: false),
        tool("allward_focus", "Focus one exact pane generation.", mutationSchema([:]), readOnly: false),
        tool("allward_board", "Read the deterministic board snapshot in grant scope.", schema([:], []), readOnly: true),
        tool(
            "allward_router",
            "Read the deterministic attention router snapshot in grant scope.",
            schema([:], []),
            readOnly: true
        ),
        tool("allward_rooms", "List Rooms in the caller's grant scope.", schema([:], []), readOnly: true),
        tool("allward_set_room", "Set the Room for one window generation.", windowMutationSchema(), readOnly: false),
        tool("allward_teleport", "Teleport focus to another receiver-issued pane.", mutationSchema([
            "destination": uuid("Receiver-issued destination pane identifier")
        ]), readOnly: false),
        tool("allward_create_record", "Create an MCP-authored normalized record with receiver-owned provenance.",
             recordSchema(includeContent: true, includeRevision: false, includeReason: false), readOnly: false),
        tool("allward_update_record", "Update one live MCP-authored record at its exact revision.",
             recordSchema(includeContent: true, includeRevision: true, includeReason: false), readOnly: false),
        tool("allward_end_record", "End one live MCP-authored record at its exact revision.",
             recordSchema(includeContent: false, includeRevision: true, includeReason: true), readOnly: false)
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: JSONValue,
        readOnly: Bool
    ) -> MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: .object([
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(!readOnly && ["allward_close_pane", "allward_end_record"].contains(name)),
                "idempotentHint": .bool(!readOnly),
                "openWorldHint": .bool(false)
            ])
        )
    }

    private static func schema(_ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    private static func targetSchema() -> JSONValue { schema(["target": target], ["target"]) }

    private static func mutationSchema(
        _ additional: [String: JSONValue],
        optional: Set<String> = []
    ) -> JSONValue {
        var properties = additional
        properties["target"] = target
        properties["generation"] = integer("Current receiver generation", 0, nil)
        properties["invocation_id"] = uuid("Caller invocation idempotency key")
        let required = properties.keys.filter { !optional.contains($0) }.sorted()
        return schema(properties, required)
    }

    private static func windowMutationSchema() -> JSONValue {
        schema([
            "room_id": uuid("Receiver-issued Room identifier"),
            "window_id": uuid("Receiver-issued window identifier"),
            "generation": integer("Current receiver generation", 0, nil),
            "invocation_id": uuid("Caller invocation idempotency key")
        ], ["room_id", "window_id", "generation", "invocation_id"])
    }

    private static func recordSchema(
        includeContent: Bool,
        includeRevision: Bool,
        includeReason: Bool
    ) -> JSONValue {
        var properties: [String: JSONValue] = [
            "target": target,
            "generation": integer("Current receiver generation", 0, nil),
            "logical_key": string("Caller logical key; identity-shaped prefixes are forbidden", minLength: 1),
            "invocation_id": uuid("Caller invocation idempotency key")
        ]
        if includeContent {
            properties["kind"] = enumeration("Normalized record kind", NormalizedRecord.Kind.allCases.map(\.rawValue))
            properties["title"] = string("Short factual title", minLength: 1)
            properties["detail"] = string("Optional factual detail")
            properties["agent_state"] = string("Optional source agent state")
        }
        if includeRevision { properties["expected_revision"] = integer("Exact receiver revision", 0, nil) }
        if includeReason { properties["reason"] = string("Reason for ending the record", minLength: 1) }
        let optional: Set<String> = ["detail", "agent_state"]
        return schema(properties, properties.keys.filter { !optional.contains($0) }.sorted())
    }

    private static func string(_ description: String, minLength: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let minLength { value["minLength"] = .integer(Int64(minLength)) }
        return .object(value)
    }

    private static func uuid(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "format": .string("uuid"), "description": .string(description)])
    }

    private static func integer(_ description: String, _ minimum: Int, _ maximum: Int?) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("integer"),
            "minimum": .integer(Int64(minimum)),
            "description": .string(description)
        ]
        if let maximum { value["maximum"] = .integer(Int64(maximum)) }
        return .object(value)
    }

    private static func number(_ description: String, _ minimum: Double, _ maximum: Double) -> JSONValue {
        .object([
            "type": .string("number"),
            "minimum": .number(minimum),
            "maximum": .number(maximum),
            "description": .string(description)
        ])
    }

    private static func enumeration(_ description: String, _ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(JSONValue.string))
        ])
    }
}
