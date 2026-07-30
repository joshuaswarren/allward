import AllwardCore
import Foundation

public enum MCPProtocolRevision: String, Codable, Hashable, Sendable, CaseIterable {
    case legacy = "2024-11-05"
    case modern = "2026-07-28"
}

public enum MCPTransportAdapter: String, Codable, Hashable, Sendable {
    case stdioLineDelimited
    case stdioContentLength
}

public enum MCPToolCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case listPanes, readScreen, readHistory, sendText, sendKeys, runCommand
    case readLastCommand, readExitCode, splitPane, createTab, closePane, focusPane
    case readBoard, readRouter, listRooms, setRoom, teleport
    case createRecord, updateRecord, endRecord, recoveryLookup
}

public struct MCPGrantTargetScope: Codable, Hashable, Sendable {
    public var allTargets: Bool
    public var rooms: Set<RoomID>
    public var sessions: Set<SessionID>
    public var panes: Set<PaneID>

    public init(
        allTargets: Bool = false,
        rooms: Set<RoomID> = [],
        sessions: Set<SessionID> = [],
        panes: Set<PaneID> = []
    ) {
        self.allTargets = allTargets
        self.rooms = rooms
        self.sessions = sessions
        self.panes = panes
    }

    public func allows(_ target: Target) -> Bool {
        guard !allTargets else { return true }
        guard rooms.contains(target.room) else { return false }
        if let session = target.session, !sessions.contains(session) { return false }
        if let pane = target.pane, !panes.contains(pane) { return false }
        return true
    }

    public func allows(room: RoomID) -> Bool { allTargets || rooms.contains(room) }
    public func allows(session: SessionID) -> Bool { allTargets || sessions.contains(session) }
    public func allows(pane: PaneID) -> Bool { allTargets || panes.contains(pane) }
}

public struct MCPGrant: Codable, Hashable, Sendable {
    public var id: UUID
    public var clientID: String
    public var invocationNamespace: String
    public var serverInstanceAudience: String
    public var protocolRevision: MCPProtocolRevision
    public var transport: MCPTransportAdapter
    public var launcherNonce: String
    public var channelNonce: String
    public var presenterID: String
    public var capabilities: Set<MCPToolCapability>
    public var targetScope: MCPGrantTargetScope
    public var issuedAt: Date
    public var expiresAt: Date
    public var signature: Data
    public init(
        id: UUID,
        clientID: String,
        invocationNamespace: String,
        serverInstanceAudience: String,
        protocolRevision: MCPProtocolRevision,
        transport: MCPTransportAdapter,
        launcherNonce: String,
        channelNonce: String,
        presenterID: String,
        capabilities: Set<MCPToolCapability>,
        targetScope: MCPGrantTargetScope,
        issuedAt: Date,
        expiresAt: Date,
        signature: Data
    ) {
        self.id = id
        self.clientID = clientID
        self.invocationNamespace = invocationNamespace
        self.serverInstanceAudience = serverInstanceAudience
        self.protocolRevision = protocolRevision
        self.transport = transport
        self.launcherNonce = launcherNonce
        self.channelNonce = channelNonce
        self.presenterID = presenterID
        self.capabilities = capabilities
        self.targetScope = targetScope
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

}

public struct MCPConnectionBinding: Codable, Hashable, Sendable {
    public var serverInstanceAudience: String
    public var protocolRevision: MCPProtocolRevision
    public var transport: MCPTransportAdapter
    public var launcherNonce: String
    public var channelNonce: String
    public var presenterID: String
    public init(
        serverInstanceAudience: String,
        protocolRevision: MCPProtocolRevision,
        transport: MCPTransportAdapter,
        launcherNonce: String,
        channelNonce: String,
        presenterID: String
    ) {
        self.serverInstanceAudience = serverInstanceAudience
        self.protocolRevision = protocolRevision
        self.transport = transport
        self.launcherNonce = launcherNonce
        self.channelNonce = channelNonce
        self.presenterID = presenterID
    }
}

public protocol MCPGrantAuthenticating: Sendable {
    func authenticate(_ grant: MCPGrant) async throws
}

public enum MCPAuthorizationError: Error, Hashable, Sendable, CustomStringConvertible {
    case unauthenticated
    case invalidGrant(String)
    case expiredGrant
    case revokedGrant
    case retiredGrant
    case presenterReplay
    case protocolIdentityMismatch
    case capabilityDenied(MCPToolCapability)
    case targetOutOfScope(Target)
    case roomOutOfScope(RoomID)
    case paneOutOfScope(PaneID)
    case windowOutOfScope(WindowID)
    case missingInvocationID

    public var code: String {
        switch self {
        case .unauthenticated: "unauthenticated"
        case .invalidGrant: "invalid_grant"
        case .expiredGrant: "expired_grant"
        case .revokedGrant: "revoked_grant"
        case .retiredGrant: "retired_grant"
        case .presenterReplay: "presenter_replay"
        case .protocolIdentityMismatch: "protocol_identity_mismatch"
        case .capabilityDenied: "capability_denied"
        case .targetOutOfScope, .roomOutOfScope, .paneOutOfScope, .windowOutOfScope: "target_out_of_scope"
        case .missingInvocationID: "missing_invocation_id"
        }
    }

    public var description: String {
        switch self {
        case .unauthenticated: "The MCP connection has not presented an app-issued grant"
        case let .invalidGrant(reason): "The app-issued grant is invalid: \(reason)"
        case .expiredGrant: "The MCP grant has expired; start a new Allward MCP connection"
        case .revokedGrant: "The MCP grant was revoked; request a new grant from Allward"
        case .retiredGrant: "The MCP grant belongs to a retired server process; only recovery lookup is available"
        case .presenterReplay: "The grant was presented from a different process, channel, or presenter"
        case .protocolIdentityMismatch: "The protocol client identity does not match the app-issued grant identity"
        case let .capabilityDenied(capability): "The grant does not allow \(capability.rawValue)"
        case let .targetOutOfScope(target): "The grant does not include target \(target.description)"
        case let .roomOutOfScope(room): "The grant does not include room \(room.description)"
        case let .paneOutOfScope(pane): "The grant does not include pane \(pane.rawValue.uuidString.lowercased())"
        case let .windowOutOfScope(window):
            "The grant does not include window \(window.rawValue.uuidString.lowercased())"
        case .missingInvocationID: "Mutating tool calls require a non-empty invocation_id"
        }
    }
}

public struct MCPCallContext: Hashable, Sendable {
    public var clientID: String
    public var grantID: UUID
    public var grantNamespace: String
    public var targetScope: MCPGrantTargetScope
    public var invocationID: String?
}

public actor CallerCapabilityAuthorizer {
    private let grant: MCPGrant
    private let binding: MCPConnectionBinding
    private let authenticator: any MCPGrantAuthenticating
    private let clock: any AllwardClock
    private var revoked = false
    private var retired = false

    public init(
        grant: MCPGrant,
        binding: MCPConnectionBinding,
        authenticator: any MCPGrantAuthenticating,
        clock: any AllwardClock = SystemClock()
    ) {
        self.grant = grant
        self.binding = binding
        self.authenticator = authenticator
        self.clock = clock
    }

    public func validate(
        capability: MCPToolCapability,
        target: Target? = nil,
        room: RoomID? = nil,
        invocationID: String? = nil,
        assertedClientID: String? = nil,
        mutation: Bool = false
    ) async throws -> MCPCallContext {
        try await validateConnection(assertedClientID: assertedClientID)
        guard grant.capabilities.contains(capability) else {
            throw MCPAuthorizationError.capabilityDenied(capability)
        }
        if let target, !grant.targetScope.allows(target) {
            throw MCPAuthorizationError.targetOutOfScope(target)
        }
        if let room, !grant.targetScope.allows(room: room) {
            throw MCPAuthorizationError.roomOutOfScope(room)
        }
        let cleanInvocationID = invocationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mutation, cleanInvocationID?.isEmpty != false {
            throw MCPAuthorizationError.missingInvocationID
        }
        return MCPCallContext(
            clientID: grant.clientID,
            grantID: grant.id,
            grantNamespace: grant.invocationNamespace,
            targetScope: grant.targetScope,
            invocationID: cleanInvocationID
        )
    }

    public func validateConnection(assertedClientID: String?) async throws {
        try validateBindings()
        guard !retired else { throw MCPAuthorizationError.retiredGrant }
        guard !revoked else { throw MCPAuthorizationError.revokedGrant }
        guard clock.now < grant.expiresAt else { throw MCPAuthorizationError.expiredGrant }
        try await authenticator.authenticate(grant)
        if let assertedClientID, assertedClientID != grant.clientID {
            throw MCPAuthorizationError.protocolIdentityMismatch
        }
    }

    public func authoredAuthorityNamespace() -> String { grant.invocationNamespace }

    public func validateScopedPane(_ pane: PaneID) async throws {
        try await validateConnection(assertedClientID: nil)
        guard grant.targetScope.allows(pane: pane) else {
            throw MCPAuthorizationError.paneOutOfScope(pane)
        }
    }

    public func revoke() { revoked = true }
    public func retireForServerRelaunch() { retired = true }


    private func validateBindings() throws {
        guard grant.serverInstanceAudience == binding.serverInstanceAudience else {
            throw MCPAuthorizationError.invalidGrant("wrong server-instance audience")
        }
        guard grant.protocolRevision == binding.protocolRevision, grant.transport == binding.transport else {
            throw MCPAuthorizationError.invalidGrant("wrong protocol era or transport")
        }
        guard grant.launcherNonce == binding.launcherNonce,
              grant.channelNonce == binding.channelNonce,
              grant.presenterID == binding.presenterID else {
            throw MCPAuthorizationError.presenterReplay
        }
        guard grant.issuedAt <= clock.now, grant.expiresAt > grant.issuedAt else {
            throw MCPAuthorizationError.invalidGrant("invalid validity interval")
        }
    }
}

public struct MCPMutationKey: Codable, Hashable, Sendable {
    public var clientID: String
    public var grantNamespace: String
    public var invocationID: String

    public init(clientID: String, grantNamespace: String, invocationID: String) {
        self.clientID = clientID
        self.grantNamespace = grantNamespace
        self.invocationID = invocationID
    }
}

public struct MCPMutationDescriptor: Codable, Hashable, Sendable {
    public var operation: String
    public var canonicalArguments: String
    public var exactTarget: String

    public init(operation: String, canonicalArguments: String, exactTarget: String) {
        self.operation = operation
        self.canonicalArguments = canonicalArguments
        self.exactTarget = exactTarget
    }
}

public enum MCPMutationState: Codable, Hashable, Sendable {
    case received
    case dispatching
    case committed(JSONValue)
    case completed(JSONValue)
    case cancelledBeforeCommit
    case outcomeUnknown
}

public struct MCPMutationOutcome: Codable, Hashable, Sendable {
    public var key: MCPMutationKey
    public var descriptor: MCPMutationDescriptor
    public var state: MCPMutationState
}

public enum MCPMutationLedgerError: Error, Hashable, Sendable, CustomStringConvertible {
    case invocationConflict
    case outcomeUnknown
    case cancelledBeforeCommit
    case recoveryDenied(String)
    case persistenceFailed(String)
    case capacityExceeded

    public var description: String {
        switch self {
        case .invocationConflict: "The invocation_id was already used with different arguments"
        case .outcomeUnknown: "The prior dispatch may have committed; recovery lookup cannot redispatch it"
        case .cancelledBeforeCommit: "The prior invocation was cancelled before its commit boundary"
        case let .recoveryDenied(reason): "Recovery lookup denied: \(reason)"
        case let .persistenceFailed(reason): "The mutation ledger could not persist its commit state: \(reason)"
        case .capacityExceeded: "The mutation ledger retention bound is full; retry after the grant retires"
        }
    }
}

public struct MCPRecoveryAuthority: Codable, Hashable, Sendable {
    public var transactionID: UUID
    public var clientID: String
    public var retiredGrantNamespace: String
    public var invocationID: String
    public var persistentAudience: String
    public var serverProcessNonce: String
    public var channelNonce: String
    public var presenterID: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var signature: Data
}

public struct MCPRecoveryBinding: Hashable, Sendable {
    public var persistentAudience: String
    public var serverProcessNonce: String
    public var channelNonce: String
    public var presenterID: String
}

public protocol MCPRecoveryAuthenticating: Sendable {
    func authenticate(_ authority: MCPRecoveryAuthority) async throws
}

public actor MCPMutationLedger {
    private struct Entry: Codable, Sendable {
        var outcome: MCPMutationOutcome
        var ordinal: UInt64
    }

    private struct Manifest: Codable, Sendable {
        var entries: [Entry]
        var nextOrdinal: UInt64
        var consumedRecoveryTransactions: Set<UUID>
    }

    private var entries: [MCPMutationKey: Entry]
    private var inFlight: [MCPMutationKey: Task<JSONValue, Error>] = [:]
    private var nextOrdinal: UInt64
    private var consumedRecoveryTransactions: Set<UUID>
    private let maximumEntries: Int
    private let storageURL: URL?
    private let loadFailure: String?

    public init(maximumEntries: Int = 1_024, storageURL: URL? = nil) {
        self.maximumEntries = max(1, maximumEntries)
        self.storageURL = storageURL
        if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                var recovered: [MCPMutationKey: Entry] = [:]
                for var entry in manifest.entries {
                    switch entry.outcome.state {
                    case .received: entry.outcome.state = .cancelledBeforeCommit
                    case .dispatching: entry.outcome.state = .outcomeUnknown
                    default: break
                    }
                    recovered[entry.outcome.key] = entry
                }
                entries = recovered
                nextOrdinal = manifest.nextOrdinal
                consumedRecoveryTransactions = manifest.consumedRecoveryTransactions
                loadFailure = nil
            } catch {
                entries = [:]
                nextOrdinal = 0
                consumedRecoveryTransactions = []
                loadFailure = String(describing: error)
            }
        } else {
            entries = [:]
            nextOrdinal = 0
            consumedRecoveryTransactions = []
            loadFailure = nil
        }
    }

    public func perform(
        key: MCPMutationKey,
        descriptor: MCPMutationDescriptor,
        dispatch: @escaping @Sendable () async throws -> JSONValue
    ) async throws -> JSONValue {
        if let loadFailure {
            throw MCPMutationLedgerError.persistenceFailed("stored ledger is unreadable: \(loadFailure)")
        }
        if let entry = entries[key] {
            guard entry.outcome.descriptor == descriptor else {
                throw MCPMutationLedgerError.invocationConflict
            }
            switch entry.outcome.state {
            case let .committed(result), let .completed(result): return result
            case .outcomeUnknown: throw MCPMutationLedgerError.outcomeUnknown
            case .cancelledBeforeCommit: throw MCPMutationLedgerError.cancelledBeforeCommit
            case .received, .dispatching:
                guard let task = inFlight[key] else { throw MCPMutationLedgerError.outcomeUnknown }
                return try await task.value
            }
        }

        guard entries.count < maximumEntries else {
            throw MCPMutationLedgerError.capacityExceeded
        }
        try record(key: key, descriptor: descriptor, state: .received)
        try update(key: key, state: .dispatching)
        let task = Task { try await dispatch() }
        inFlight[key] = task
        do {
            let result = try await task.value
            try update(key: key, state: .committed(result))
            inFlight[key] = nil
            return result
        } catch {
            try? update(key: key, state: .outcomeUnknown)
            inFlight[key] = nil
            throw error
        }
    }

    public func markCompleted(key: MCPMutationKey, result: JSONValue) throws {
        guard entries[key] != nil else { return }
        try update(key: key, state: .completed(result))
    }

    public func resolveOutcomeUnknown(key: MCPMutationKey, result: JSONValue) throws {
        guard let entry = entries[key], case .outcomeUnknown = entry.outcome.state else {
            throw MCPMutationLedgerError.invocationConflict
        }
        try update(key: key, state: .committed(result))
    }

    public func markCancelledBeforeCommit(key: MCPMutationKey) throws {
        guard let entry = entries[key], case .outcomeUnknown = entry.outcome.state else {
            throw MCPMutationLedgerError.invocationConflict
        }
        try update(key: key, state: .cancelledBeforeCommit)
    }

    public func lookup(_ key: MCPMutationKey) -> MCPMutationOutcome? { entries[key]?.outcome }

    public func recover(
        authority: MCPRecoveryAuthority,
        binding: MCPRecoveryBinding,
        now: Date,
        authenticator: any MCPRecoveryAuthenticating
    ) async throws -> MCPMutationOutcome? {
        if let loadFailure {
            throw MCPMutationLedgerError.persistenceFailed("stored ledger is unreadable: \(loadFailure)")
        }
        try await authenticator.authenticate(authority)
        guard !consumedRecoveryTransactions.contains(authority.transactionID) else {
            throw MCPMutationLedgerError.recoveryDenied("authority already consumed")
        }
        guard authority.issuedAt <= now else {
            throw MCPMutationLedgerError.recoveryDenied("authority is not active yet")
        }
        guard now < authority.expiresAt else {
            throw MCPMutationLedgerError.recoveryDenied("authority expired")
        }
        guard authority.persistentAudience == binding.persistentAudience,
              authority.serverProcessNonce == binding.serverProcessNonce,
              authority.channelNonce == binding.channelNonce,
              authority.presenterID == binding.presenterID else {
            throw MCPMutationLedgerError.recoveryDenied("binding mismatch")
        }
        consumedRecoveryTransactions.insert(authority.transactionID)
        try persist()
        let key = MCPMutationKey(
            clientID: authority.clientID,
            grantNamespace: authority.retiredGrantNamespace,
            invocationID: authority.invocationID
        )
        return entries[key]?.outcome
    }

    private func record(key: MCPMutationKey, descriptor: MCPMutationDescriptor, state: MCPMutationState) throws {
        let outcome = MCPMutationOutcome(key: key, descriptor: descriptor, state: state)
        entries[key] = Entry(outcome: outcome, ordinal: nextOrdinal)
        nextOrdinal &+= 1
        try persist()
    }

    private func update(key: MCPMutationKey, state: MCPMutationState) throws {
        guard var entry = entries[key] else { return }
        entry.outcome.state = state
        entries[key] = entry
        try persist()
    }

    private func persist() throws {
        if let loadFailure {
            throw MCPMutationLedgerError.persistenceFailed("stored ledger is unreadable: \(loadFailure)")
        }
        guard let storageURL else { return }
        do {
            let manifest = Manifest(
                entries: entries.values.sorted { $0.ordinal < $1.ordinal },
                nextOrdinal: nextOrdinal,
                consumedRecoveryTransactions: consumedRecoveryTransactions
            )
            let data = try JSONEncoder().encode(manifest)
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw MCPMutationLedgerError.persistenceFailed(String(describing: error))
        }
    }
}
