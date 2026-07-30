import AllwardCore
import Foundation

// Allward protocol v0 (SPEC §6). Line-delimited JSON over a receiver-issued
// descriptor. The transport is address-agnostic: publishers read the endpoint
// from their environment and never assume `/tmp`, a socket family, or a path.
//
// The protocol never carries terminal-content byte streams, publisher-selected
// colours, sounds, view code, or Room authority.

public enum AllwardProtocolVersion {
    public static let major = 0
    /// Capabilities a publisher may declare. Unknown optional capabilities in
    /// the same major are ignored and counted, never fatal.
    public enum Capability: String, Codable, Hashable, Sendable, CaseIterable {
        case plans
        case sessionUpdates
        case permissions
        case commandRegions
    }
}

/// The receiver-issued key a publisher must authenticate to. One key binds one
/// exact target; a publisher can never construct or widen it.
public struct PublisherTargetKey: Hashable, Sendable, Codable {
    public var descriptor: String
    public var target: Target
    public var credentialGeneration: Generation

    public init(descriptor: String, target: Target, credentialGeneration: Generation) {
        self.descriptor = descriptor
        self.target = target
        self.credentialGeneration = credentialGeneration
    }
}

/// Where a record came from. Receiver-stamped only: a publisher-supplied
/// provenance or adapter reference is rejected before normalization.
public enum RecordSource: String, Codable, Hashable, Sendable, CaseIterable {
    case publisherDirect = "publisher_direct"
    case adapterAssociated = "adapter_associated"
    case mcpAuthored = "mcp_authored"
    case shellIntegration = "shell_integration"
    case terminalOSC133 = "terminal_osc133"
}

/// Publisher-declared handshake.
public struct GrantRequest: Codable, Hashable, Sendable {
    public var protocolMajor: Int
    public var capabilities: [AllwardProtocolVersion.Capability]
    public var harness: String
    public var publisherName: String
    public var descriptor: String
    public var sessionHint: String?
    public var roomHint: String?
    public var requestedLeaseSeconds: Double?

    public init(
        protocolMajor: Int = AllwardProtocolVersion.major,
        capabilities: [AllwardProtocolVersion.Capability],
        harness: String,
        publisherName: String,
        descriptor: String,
        sessionHint: String? = nil,
        roomHint: String? = nil,
        requestedLeaseSeconds: Double? = nil
    ) {
        self.protocolMajor = protocolMajor
        self.capabilities = capabilities
        self.harness = harness
        self.publisherName = publisherName
        self.descriptor = descriptor
        self.sessionHint = sessionHint
        self.roomHint = roomHint
        self.requestedLeaseSeconds = requestedLeaseSeconds
    }
}

/// Receiver reply to a grant request.
public struct GrantResponse: Codable, Hashable, Sendable {
    public var accepted: Bool
    public var publisher: PublisherID?
    public var epoch: Generation
    public var leaseSeconds: Double
    public var acceptedCapabilities: [AllwardProtocolVersion.Capability]
    public var rejectionReason: String?

    public init(
        accepted: Bool,
        publisher: PublisherID?,
        epoch: Generation,
        leaseSeconds: Double,
        acceptedCapabilities: [AllwardProtocolVersion.Capability],
        rejectionReason: String? = nil
    ) {
        self.accepted = accepted
        self.publisher = publisher
        self.epoch = epoch
        self.leaseSeconds = leaseSeconds
        self.acceptedCapabilities = acceptedCapabilities
        self.rejectionReason = rejectionReason
    }
}

// MARK: - ACP-shaped payloads

/// An ACP plan entry: one open loop.
public struct PlanEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
        case blocked
        case abandoned
    }

    public var id: String
    public var content: String
    public var status: Status
    public var priority: Int?

    public init(id: String, content: String, status: Status, priority: Int? = nil) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }

    public var isOpen: Bool { status == .pending || status == .inProgress || status == .blocked }
}

/// An ACP session update: agent lifecycle and current activity facts.
public struct SessionUpdate: Codable, Hashable, Sendable {
    public var sessionName: String?
    public var activity: String?
    public var lifecycle: WorkLifecycle
    public var model: String?
    public var progressLabel: String?

    public init(
        sessionName: String? = nil,
        activity: String? = nil,
        lifecycle: WorkLifecycle = .none,
        model: String? = nil,
        progressLabel: String? = nil
    ) {
        self.sessionName = sessionName
        self.activity = activity
        self.lifecycle = lifecycle
        self.model = model
        self.progressLabel = progressLabel
    }
}

/// An ACP permission request. Option identity never derives from display text.
public struct PermissionRequest: Codable, Hashable, Sendable, Identifiable {
    public struct Option: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// The least-destructive option receives initial focus (§23.1.1).
        public var isLeastDestructive: Bool

        public init(id: String, label: String, isLeastDestructive: Bool = false) {
            self.id = id
            self.label = label
            self.isLeastDestructive = isLeastDestructive
        }
    }

    public var id: String
    public var verb: String
    public var subject: String
    public var options: [Option]
    public var expiresAt: Date?

    public init(
        id: String, verb: String, subject: String, options: [Option], expiresAt: Date? = nil
    ) {
        self.id = id
        self.verb = verb
        self.subject = subject
        self.options = options
        self.expiresAt = expiresAt
    }
}

/// A publisher-reported command region (lane 1 and lane 2 of DECISIONS 13-rev).
public struct CommandRegionUpdate: Codable, Hashable, Sendable {
    public var commandID: String
    public var phase: String
    public var commandText: String?
    public var workingDirectory: String?
    public var exitCode: Int32?

    public init(
        commandID: String,
        phase: String,
        commandText: String? = nil,
        workingDirectory: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.commandID = commandID
        self.phase = phase
        self.commandText = commandText
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
    }
}

// MARK: - Frames

public enum PublicationPayload: Codable, Hashable, Sendable {
    case plan([PlanEntry])
    case sessionUpdate(SessionUpdate)
    case permissionRequest(PermissionRequest)
    case commandRegion(CommandRegionUpdate)
    case heartbeat
}

/// One publisher publication. Sequence is publisher-monotonic within an epoch;
/// a duplicate or lower sequence is ignored and counted.
public struct PublicationFrame: Codable, Hashable, Sendable {
    public var epoch: Generation
    public var sequence: UInt64
    public var payload: PublicationPayload

    public init(epoch: Generation, sequence: UInt64, payload: PublicationPayload) {
        self.epoch = epoch
        self.sequence = sequence
        self.payload = payload
    }
}

/// The frozen binding a decision carries end to end. Every field is receiver-
/// owned and resolved before dispatch, so a reply for a superseded target,
/// credential generation, or publisher epoch is rejected before it can touch
/// the ledger (SPEC §6 "Permission decision transaction").
public struct DecisionBinding: Codable, Hashable, Sendable {
    public var targetKey: PublisherTargetKey
    /// The normalized record the decision acts on.
    public var recordID: RecordID
    /// The publication sequence that made the record actionable.
    public var recordSequence: UInt64
    public var connectionGeneration: Generation
    public var ownershipGeneration: Generation
    public var publisherEpoch: Generation

    public init(
        targetKey: PublisherTargetKey,
        recordID: RecordID,
        recordSequence: UInt64,
        connectionGeneration: Generation,
        ownershipGeneration: Generation,
        publisherEpoch: Generation
    ) {
        self.targetKey = targetKey
        self.recordID = recordID
        self.recordSequence = recordSequence
        self.connectionGeneration = connectionGeneration
        self.ownershipGeneration = ownershipGeneration
        self.publisherEpoch = publisherEpoch
    }
}

/// Receiver-to-publisher decision dispatch (SPEC §6 permission transaction).
public struct DecisionFrame: Codable, Hashable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var permissionRequestID: String
    public var optionID: String
    public var epoch: Generation
    public var binding: DecisionBinding

    public init(
        decisionID: String,
        decisionGeneration: Generation,
        permissionRequestID: String,
        optionID: String,
        epoch: Generation,
        binding: DecisionBinding
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.permissionRequestID = permissionRequestID
        self.optionID = optionID
        self.epoch = epoch
        self.binding = binding
    }
}

/// Publisher status for a dispatched decision. Ordinals are monotonic, so a
/// late lower-ordinal status can never regress the ledger.
public enum DecisionStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case accepted
    case committed
    case rejected
    case cancelled
    case acknowledged

    public var ordinal: Int {
        switch self {
        case .accepted: 1
        case .rejected, .cancelled, .committed: 2
        case .acknowledged: 3
        }
    }

    public var isFinal: Bool {
        self == .committed || self == .rejected || self == .cancelled
    }
}

public struct DecisionStatusFrame: Codable, Hashable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var status: DecisionStatus
    /// Publisher-asserted ordinal. It must match `status.ordinal`; a mismatch
    /// is a binding failure rather than a hint.
    public var statusOrdinal: Int
    public var binding: DecisionBinding
    /// Echo of the final outcome when the publisher acknowledges one, so an
    /// acknowledgment can never be mistaken for a commit.
    public var finalOutcome: DecisionStatus?
    /// Publisher-side effect receipt for a committed decision.
    public var receipt: String?
    public var reason: String?

    public init(
        decisionID: String,
        decisionGeneration: Generation,
        status: DecisionStatus,
        statusOrdinal: Int,
        binding: DecisionBinding,
        finalOutcome: DecisionStatus? = nil,
        receipt: String? = nil,
        reason: String? = nil
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.status = status
        self.statusOrdinal = statusOrdinal
        self.binding = binding
        self.finalOutcome = finalOutcome
        self.receipt = receipt
        self.reason = reason
    }
}

/// Lookup-only recovery for an outcome the receiver never observed. It asks
/// what happened; it can never re-dispatch (SPEC §6).
public struct DecisionQueryFrame: Codable, Hashable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var binding: DecisionBinding

    public init(
        decisionID: String, decisionGeneration: Generation, binding: DecisionBinding
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.binding = binding
    }
}

/// Receiver-initiated cancellation while the transaction is still cancellable.
public struct DecisionCancelFrame: Codable, Hashable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var binding: DecisionBinding

    public init(
        decisionID: String, decisionGeneration: Generation, binding: DecisionBinding
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.binding = binding
    }
}

/// Receiver acknowledgment that a final outcome was delivered. It confirms
/// delivery only and never promotes a status.
public struct DecisionAckFrame: Codable, Hashable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var acknowledgedOutcome: DecisionStatus
    public var binding: DecisionBinding

    public init(
        decisionID: String,
        decisionGeneration: Generation,
        acknowledgedOutcome: DecisionStatus,
        binding: DecisionBinding
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.acknowledgedOutcome = acknowledgedOutcome
        self.binding = binding
    }
}

/// Every line on the wire is exactly one of these.
public enum AllwardFrame: Codable, Hashable, Sendable {
    case grantRequest(GrantRequest)
    case grantResponse(GrantResponse)
    case publication(PublicationFrame)
    case decision(DecisionFrame)
    case decisionStatus(DecisionStatusFrame)
    case decisionQuery(DecisionQueryFrame)
    case decisionCancel(DecisionCancelFrame)
    case decisionAck(DecisionAckFrame)
}
