import AllwardCore
import Foundation

public struct PermissionDecisionBinding: Codable, Equatable, Sendable {
    public var permissionRequestID: String
    public var optionID: String
    public var normalizedPermissionRecordID: RecordID
    public var permissionRecordSequence: UInt64
    public var publisherTargetKey: PublisherTargetKey
    public var connectionGeneration: Generation
    public var publisherOwnershipGeneration: Generation
    public var publisherEpoch: Generation

    public init(
        permissionRequestID: String,
        optionID: String,
        normalizedPermissionRecordID: RecordID,
        permissionRecordSequence: UInt64,
        publisherTargetKey: PublisherTargetKey,
        connectionGeneration: Generation,
        publisherOwnershipGeneration: Generation,
        publisherEpoch: Generation
    ) {
        self.permissionRequestID = permissionRequestID
        self.optionID = optionID
        self.normalizedPermissionRecordID = normalizedPermissionRecordID
        self.permissionRecordSequence = permissionRecordSequence
        self.publisherTargetKey = publisherTargetKey
        self.connectionGeneration = connectionGeneration
        self.publisherOwnershipGeneration = publisherOwnershipGeneration
        self.publisherEpoch = publisherEpoch
    }

    public var descriptorGeneration: Generation {
        publisherTargetKey.credentialGeneration
    }

    public var decisionBinding: DecisionBinding {
        DecisionBinding(
            targetKey: publisherTargetKey,
            recordID: normalizedPermissionRecordID,
            recordSequence: permissionRecordSequence,
            connectionGeneration: connectionGeneration,
            ownershipGeneration: publisherOwnershipGeneration,
            publisherEpoch: publisherEpoch
        )
    }
}

public enum PermissionDecisionPhase: String, Codable, Equatable, Sendable {
    case dispatching
    case accepted
    case committed
    case rejected
    case cancelled
    case acknowledged
    case outcomeUnknown = "outcome_unknown"
}

public enum PermissionDecisionFinalOutcome: String, Codable, Equatable, Sendable {
    case committed
    case rejected
    case cancelled
    case outcomeUnknown = "outcome_unknown"
}

public enum PermissionDecisionRecordState: String, Codable, Equatable, Sendable {
    case pending
    case granted
    case denied
    case cancelled
    case outcomeUnknown = "outcome_unknown"
}

public enum DecisionStatusReceiptRejection: String, Codable, Equatable, Sendable {
    case wrongDecision
    case staleGeneration
    case wrongTarget
    case ordinalRegression
    case ordinalCollision
    case invalidTransition
    case wrongBinding
    case ordinalMismatch
    case acknowledgmentMismatch
    case missingCommitReceipt
}

public struct DecisionStatusReceipt: Codable, Equatable, Sendable {
    public var frame: DecisionStatusFrame
    public var sourceTarget: PublisherTargetKey
    public var applied: Bool
    public var rejection: DecisionStatusReceiptRejection?

    public init(
        frame: DecisionStatusFrame,
        sourceTarget: PublisherTargetKey,
        applied: Bool,
        rejection: DecisionStatusReceiptRejection?
    ) {
        self.frame = frame
        self.sourceTarget = sourceTarget
        self.applied = applied
        self.rejection = rejection
    }
}

public struct PermissionDecisionSnapshot: Codable, Equatable, Sendable {
    public var decisionID: String
    public var decisionGeneration: Generation
    public var binding: PermissionDecisionBinding
    public var phase: PermissionDecisionPhase
    public var finalOutcome: PermissionDecisionFinalOutcome?
    public var recordState: PermissionDecisionRecordState
    public var lastStatusOrdinal: Int
    public var receipts: [DecisionStatusReceipt]

    public init(
        decisionID: String,
        decisionGeneration: Generation,
        binding: PermissionDecisionBinding,
        phase: PermissionDecisionPhase,
        finalOutcome: PermissionDecisionFinalOutcome?,
        recordState: PermissionDecisionRecordState,
        lastStatusOrdinal: Int,
        receipts: [DecisionStatusReceipt]
    ) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.binding = binding
        self.phase = phase
        self.finalOutcome = finalOutcome
        self.recordState = recordState
        self.lastStatusOrdinal = lastStatusOrdinal
        self.receipts = receipts
    }
}

public struct PermissionDecisionDispatch: Sendable {
    public let frame: DecisionFrame
    public let transaction: PermissionDecisionTransaction

    public init(frame: DecisionFrame, transaction: PermissionDecisionTransaction) {
        self.frame = frame
        self.transaction = transaction
    }
}

public actor PermissionDecisionCoordinator {
    private var nextGeneration: Generation
    private let makeDecisionID: @Sendable () -> String

    public init(
        initialGeneration: Generation = .initial.next,
        makeDecisionID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.nextGeneration = initialGeneration
        self.makeDecisionID = makeDecisionID
    }

    public func begin(_ binding: PermissionDecisionBinding) -> PermissionDecisionDispatch {
        let decisionID = makeDecisionID()
        let generation = nextGeneration
        nextGeneration = nextGeneration.next
        let frame = DecisionFrame(
            decisionID: decisionID,
            decisionGeneration: generation,
            permissionRequestID: binding.permissionRequestID,
            optionID: binding.optionID,
            epoch: binding.publisherEpoch,
            binding: binding.decisionBinding
        )
        let transaction = PermissionDecisionTransaction(
            decisionID: decisionID,
            decisionGeneration: generation,
            binding: binding
        )
        return PermissionDecisionDispatch(frame: frame, transaction: transaction)
    }
}

public actor PermissionDecisionTransaction {
    public let decisionID: String
    public let decisionGeneration: Generation
    public let binding: PermissionDecisionBinding

    private var phase: PermissionDecisionPhase = .dispatching
    private var finalOutcome: PermissionDecisionFinalOutcome?
    private var recordState: PermissionDecisionRecordState = .pending
    private var lastStatusOrdinal = 0
    private var lastStatusFrame: DecisionStatusFrame?
    private var receipts: [DecisionStatusReceipt] = []

    init(decisionID: String, decisionGeneration: Generation, binding: PermissionDecisionBinding) {
        self.decisionID = decisionID
        self.decisionGeneration = decisionGeneration
        self.binding = binding
    }

    public func process(
        _ statusFrame: DecisionStatusFrame,
        from sourceTarget: PublisherTargetKey
    ) -> PermissionDecisionSnapshot {
        if statusFrame.decisionID != decisionID {
            record(statusFrame, from: sourceTarget, rejection: .wrongDecision)
            return snapshot()
        }
        if statusFrame.decisionGeneration != decisionGeneration {
            record(statusFrame, from: sourceTarget, rejection: .staleGeneration)
            return snapshot()
        }
        if sourceTarget != binding.publisherTargetKey {
            record(statusFrame, from: sourceTarget, rejection: .wrongTarget)
            return snapshot()
        }
        if statusFrame.binding.targetKey != binding.publisherTargetKey {
            record(statusFrame, from: sourceTarget, rejection: .wrongTarget)
            return snapshot()
        }
        if statusFrame.binding != binding.decisionBinding {
            record(statusFrame, from: sourceTarget, rejection: .wrongBinding)
            return snapshot()
        }
        guard statusFrame.statusOrdinal == statusFrame.status.ordinal else {
            record(statusFrame, from: sourceTarget, rejection: .ordinalMismatch)
            return snapshot()
        }
        guard acknowledgmentMatches(statusFrame) else {
            record(statusFrame, from: sourceTarget, rejection: .acknowledgmentMismatch)
            return snapshot()
        }
        if statusFrame.status == .committed,
           statusFrame.receipt?.isEmpty != false {
            record(statusFrame, from: sourceTarget, rejection: .missingCommitReceipt)
            return snapshot()
        }

        let ordinal = statusFrame.statusOrdinal
        if ordinal < lastStatusOrdinal {
            record(statusFrame, from: sourceTarget, rejection: .ordinalRegression)
            return snapshot()
        }
        if ordinal == lastStatusOrdinal {
            if statusFrame == lastStatusFrame {
                record(statusFrame, from: sourceTarget, rejection: nil, applied: false)
            } else {
                record(statusFrame, from: sourceTarget, rejection: .ordinalCollision)
            }
            return snapshot()
        }
        guard transition(to: statusFrame.status) else {
            record(statusFrame, from: sourceTarget, rejection: .invalidTransition)
            return snapshot()
        }

        lastStatusOrdinal = ordinal
        lastStatusFrame = statusFrame
        record(statusFrame, from: sourceTarget, rejection: nil, applied: true)
        return snapshot()
    }

    public func recordResponseLoss() -> PermissionDecisionSnapshot {
        guard phase == .dispatching || phase == .accepted else { return snapshot() }
        phase = .outcomeUnknown
        finalOutcome = .outcomeUnknown
        recordState = .outcomeUnknown
        return snapshot()
    }

    public func queryFrame() -> DecisionQueryFrame? {
        guard phase == .outcomeUnknown else { return nil }
        return DecisionQueryFrame(
            decisionID: decisionID,
            decisionGeneration: decisionGeneration,
            binding: binding.decisionBinding
        )
    }

    public func cancelFrame() -> DecisionCancelFrame? {
        guard phase == .dispatching || phase == .accepted else { return nil }
        return DecisionCancelFrame(
            decisionID: decisionID,
            decisionGeneration: decisionGeneration,
            binding: binding.decisionBinding
        )
    }

    public func acknowledgmentFrame() -> DecisionAckFrame? {
        let outcome: DecisionStatus
        switch finalOutcome {
        case .committed: outcome = .committed
        case .rejected: outcome = .rejected
        case .cancelled: outcome = .cancelled
        case .outcomeUnknown, nil: return nil
        }
        return DecisionAckFrame(
            decisionID: decisionID,
            decisionGeneration: decisionGeneration,
            acknowledgedOutcome: outcome,
            binding: binding.decisionBinding
        )
    }

    public func snapshot() -> PermissionDecisionSnapshot {
        PermissionDecisionSnapshot(
            decisionID: decisionID,
            decisionGeneration: decisionGeneration,
            binding: binding,
            phase: phase,
            finalOutcome: finalOutcome,
            recordState: recordState,
            lastStatusOrdinal: lastStatusOrdinal,
            receipts: receipts
        )
    }

    private func acknowledgmentMatches(_ frame: DecisionStatusFrame) -> Bool {
        guard frame.status == .acknowledged else {
            return frame.finalOutcome == nil
        }
        switch finalOutcome {
        case .committed: return frame.finalOutcome == .committed
        case .rejected: return frame.finalOutcome == .rejected
        case .cancelled: return frame.finalOutcome == .cancelled
        case .outcomeUnknown: return frame.finalOutcome == nil
        case nil: return false
        }
    }

    private func transition(to status: DecisionStatus) -> Bool {
        switch (phase, status) {
        case (.dispatching, .accepted):
            phase = .accepted
        case (.accepted, .committed), (.outcomeUnknown, .committed):
            phase = .committed
            finalOutcome = .committed
            recordState = .granted
        case (.dispatching, .rejected), (.accepted, .rejected), (.outcomeUnknown, .rejected):
            phase = .rejected
            finalOutcome = .rejected
            recordState = .denied
        case (.dispatching, .cancelled), (.accepted, .cancelled), (.outcomeUnknown, .cancelled):
            phase = .cancelled
            finalOutcome = .cancelled
            recordState = .cancelled
        case (.outcomeUnknown, .accepted):
            phase = .accepted
            finalOutcome = nil
            recordState = .pending
        case (.committed, .acknowledged), (.rejected, .acknowledged),
             (.cancelled, .acknowledged), (.outcomeUnknown, .acknowledged):
            phase = .acknowledged
        default:
            return false
        }
        return true
    }

    private func record(
        _ frame: DecisionStatusFrame,
        from target: PublisherTargetKey,
        rejection: DecisionStatusReceiptRejection?,
        applied: Bool = false
    ) {
        receipts.append(
            DecisionStatusReceipt(
                frame: frame,
                sourceTarget: target,
                applied: applied,
                rejection: rejection
            )
        )
    }
}
