import AllwardCore
import AllwardMultiplexer
import AllwardProtocol
import Foundation

public struct NormalizedPublication: Hashable, Sendable, Codable {
    public var logicalKey: String
    public var record: NormalizedRecord
    public var usability: ComposedUsability
    public var leaseDuration: TimeInterval?
    public var transition: SurfaceTransition
    public var presence: SurfacePresence
    public var isMeaningful: Bool

    public init(
        logicalKey: String,
        record: NormalizedRecord,
        usability: ComposedUsability = .usableActionCapable,
        leaseDuration: TimeInterval? = nil,
        transition: SurfaceTransition = .semanticChange,
        presence: SurfacePresence = .background,
        isMeaningful: Bool = true
    ) {
        self.logicalKey = logicalKey
        self.record = record
        self.usability = usability
        self.leaseDuration = leaseDuration
        self.transition = transition
        self.presence = presence
        self.isMeaningful = isMeaningful
    }
}

public struct AdapterSessionPublication: Hashable, Sendable {
    public var session: AdapterSession
    public var target: Target
    public var adapterHealth: AdapterHealth
    public var control: ControlCapability
    public var leaseDuration: TimeInterval

    public init(
        session: AdapterSession,
        target: Target,
        adapterHealth: AdapterHealth = .available,
        control: ControlCapability = .available,
        leaseDuration: TimeInterval = 30
    ) {
        self.session = session
        self.target = target
        self.adapterHealth = adapterHealth
        self.control = control
        self.leaseDuration = max(0, leaseDuration)
    }
}

public struct MCPAuthoredContent: Hashable, Sendable, Codable {
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
}

public struct MCPAuthoredAuthority: Hashable, Sendable, Codable {
    public var authoritativeClientID: String
    public var grantID: String
    public var grantInvocationNamespace: String

    public init(authoritativeClientID: String, grantID: String, grantInvocationNamespace: String) {
        self.authoritativeClientID = authoritativeClientID
        self.grantID = grantID
        self.grantInvocationNamespace = grantInvocationNamespace
    }
}

public enum MCPAuthoredMutation: Hashable, Sendable, Codable {
    case create(
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID
    )
    case update(
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64
    )
    case end(
        callerLogicalKey: String,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String
    )
}

public struct MCPAuthoredMutationReceipt: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable, CaseIterable {
        case created
        case updated
        case ended
        case alreadyExists
        case notFound
        case revisionConflict
    }

    public var status: Status
    public var recordID: RecordID?
    public var incarnation: UUID?
    public var revision: UInt64?
    public var sourceEventID: UUID?
    public var commitOrdinal: UInt64?

    public init(
        status: Status,
        recordID: RecordID?,
        incarnation: UUID?,
        revision: UInt64?,
        sourceEventID: UUID?,
        commitOrdinal: UInt64?
    ) {
        self.status = status
        self.recordID = recordID
        self.incarnation = incarnation
        self.revision = revision
        self.sourceEventID = sourceEventID
        self.commitOrdinal = commitOrdinal
    }
}

public struct SurfaceSnapshot: Hashable, Sendable, Codable {
    public var records: [NormalizedRecord]
    public var board: BoardSnapshot
    public var router: RouterSnapshot
    public var digest: DigestSnapshot
    public var generation: Generation

    public init(
        records: [NormalizedRecord],
        board: BoardSnapshot,
        router: RouterSnapshot,
        digest: DigestSnapshot,
        generation: Generation
    ) {
        self.records = records
        self.board = board
        self.router = router
        self.digest = digest
        self.generation = generation
    }

    public static let empty = SurfaceSnapshot(
        records: [],
        board: .empty,
        router: .empty,
        digest: .empty,
        generation: .initial
    )
}

public actor SurfaceStore {
    private struct SupersedeKey: Hashable, Sendable {
        var publisher: PublisherID?
        var logicalKey: String
        var source: RecordSource
        var target: Target
    }

    private struct StoredRecord: Hashable, Sendable {
        var record: NormalizedRecord
        var logicalKey: String
        var usability: ComposedUsability
        var transition: SurfaceTransition
        var presence: SurfacePresence
        var leaseExpiresAt: Date?
    }

    private struct MCPKey: Hashable, Sendable {
        var callerLogicalKey: String
        var target: Target
        var authority: MCPAuthoredAuthority
    }

    private struct MCPMetadata: Hashable, Sendable {
        var key: MCPKey
        var incarnation: UUID
        var revision: UInt64
    }

    private struct MCPInvocationKey: Hashable, Sendable {
        var authority: MCPAuthoredAuthority
        var invocationID: UUID
    }

    private let clock: any AllwardClock
    private let eligibilityReducer = SurfaceEligibilityReducer()
    private let boardReducer: BoardReducer
    private var routerReducer: RouterReducer
    private let digestReducer = DigestReducer()
    private var recordsByID: [RecordID: StoredRecord] = [:]
    private var activeByKey: [SupersedeKey: RecordID] = [:]
    private var adapterRecordIDs: [String: RecordID] = [:]
    private var commandRecordIDs: [String: RecordID] = [:]
    private var mcpRecordIDs: [MCPKey: RecordID] = [:]
    private var mcpMetadata: [RecordID: MCPMetadata] = [:]
    private var mcpInvocationReceipts: [MCPInvocationKey: MCPAuthoredMutationReceipt] = [:]
    private var mcpInvocationReceiptDates: [MCPInvocationKey: Date] = [:]
    private var events: [SurfaceEvent] = []
    private var acknowledgedEventIDs: Set<SurfaceEventID> = []
    private var consumedDigestTokens: Set<DigestAcknowledgmentToken> = []
    private var hasAcknowledgedDigest = false
    private var maxAcknowledgedOrdinal: UInt64?
    private var nextEventOrdinal: UInt64 = 1
    private var nextMCPCommitOrdinal: UInt64 = 1
    private var generation: Generation = .initial

    public static let maxRetainedEventsCount: Int = 500
    public static let maxRetainedEventsAge: TimeInterval = 3600
    public static let maxConsumedDigestTokensCount: Int = 100
    public static let maxMCPInvocationReceiptsCount: Int = 200
    public static let maxMCPInvocationReceiptsAge: TimeInterval = 3600

    public var retainedEventsCount: Int { events.count }
    public var recordsCount: Int { recordsByID.count }
    public var mcpReceiptsCount: Int { mcpInvocationReceipts.count }
    public var adapterRecordIDsCount: Int { adapterRecordIDs.count }
    public var commandRecordIDsCount: Int { commandRecordIDs.count }
    public var mcpRecordIDsCount: Int { mcpRecordIDs.count }

    public init(
        clock: any AllwardClock,
        boardVisibleRowLimit: Int = 200,
        routerVisibleItemLimit: Int = 200
    ) {
        self.clock = clock
        self.boardReducer = BoardReducer(visibleRowLimit: boardVisibleRowLimit)
        self.routerReducer = RouterReducer(visibleItemLimit: routerVisibleItemLimit)
    }

    public func snapshot() -> SurfaceSnapshot {
        makeSnapshot()
    }

    public func record(id: RecordID) -> NormalizedRecord? {
        recordsByID[id]?.record
    }

    @discardableResult
    public func ingest(_ publication: NormalizedPublication) -> SurfaceSnapshot {
        if apply(publication) { generation = generation.next }
        return makeSnapshot()
    }

    @discardableResult
    public func ingest(adapterSessions: [AdapterSessionPublication]) -> SurfaceSnapshot {
        let currentKeys = Set(adapterSessions.map { adapterKey(session: $0.session, target: $0.target) })
        var changed = false
        for (key, recordID) in adapterRecordIDs.sorted(by: { $0.key < $1.key })
        where !currentKeys.contains(key) {
            guard var stored = recordsByID[recordID], stored.record.composition.freshness == .live else { continue }
            stored.record.composition.freshness = .ended
            stored.transition = .semanticChange
            stored.leaseExpiresAt = nil
            recordsByID[recordID] = stored
            _ = appendEvent(record: stored.record, transition: .semanticChange, meaningful: true)
            changed = true
        }
        let orderedSessions = adapterSessions.sorted {
            adapterKey(session: $0.session, target: $0.target)
                < adapterKey(session: $1.session, target: $1.target)
        }
        for publication in orderedSessions {
            let key = adapterKey(session: publication.session, target: publication.target)
            let recordID = adapterRecordIDs[key] ?? RecordID()
            adapterRecordIDs[key] = recordID
            var composition = SourceComposition(
                adapterHealth: publication.adapterHealth,
                adapterOwnsTarget: true,
                control: publication.control
            )
            composition.work = workLifecycle(for: publication.session.agentState)
            let record = NormalizedRecord(
                id: recordID,
                kind: .session,
                source: .adapterAssociated,
                target: publication.target,
                freshness: FreshnessStamp(observedAt: publication.session.observedAt),
                composition: composition,
                title: publication.session.title,
                detail: publication.session.workingDirectory,
                host: publication.session.host,
                workspace: publication.session.workspace,
                agentState: publication.session.agentState.rawValue,
                sequence: UInt64(publication.session.observedAt.timeIntervalSince1970.bitPattern)
            )
            let usability = usabilityForAdapter(composition)
            changed = apply(NormalizedPublication(
                logicalKey: "adapter:\(publication.session.id)",
                record: record,
                usability: usability,
                leaseDuration: publication.leaseDuration,
                transition: .semanticChange
            )) || changed
        }
        if changed { generation = generation.next }
        return makeSnapshot()
    }

    @discardableResult
    public func ingest(commandRegions: [CommandRegionUpdate], for target: Target) -> SurfaceSnapshot {
        var changed = false
        for command in commandRegions.sorted(by: commandRegionLessThan) {
            let logicalKey = commandLogicalKey(command.commandID, target: target)
            let recordID = commandRecordIDs[logicalKey] ?? RecordID()
            commandRecordIDs[logicalKey] = recordID
            let finished = command.phase == "D" || command.phase.lowercased() == "finished"
            let composition = SourceComposition(
                work: finished ? .finished : .running,
                isFinishedTransitionEvent: finished
            )
            let record = NormalizedRecord(
                id: recordID,
                kind: .command,
                source: .terminalOSC133,
                target: target,
                freshness: FreshnessStamp(observedAt: clock.now),
                composition: composition,
                title: command.commandText ?? "Shell command",
                detail: command.workingDirectory,
                command: command,
                sequence: nextEventOrdinal
            )
            changed = apply(NormalizedPublication(
                logicalKey: logicalKey,
                record: record,
                transition: finished ? .finished : .semanticChange
            )) || changed
        }
        if changed { generation = generation.next }
        return makeSnapshot()
    }

    @discardableResult
    public func ingest(mcpAuthored mutation: MCPAuthoredMutation) throws -> MCPAuthoredMutationReceipt {
        switch mutation {
        case let .create(callerLogicalKey, content, target, authority, invocationID):
            return try createMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                content: content,
                target: target,
                authority: authority,
                invocationID: invocationID
            )
        case let .update(callerLogicalKey, content, target, authority, invocationID, expectedRevision):
            return try updateMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                content: content,
                target: target,
                authority: authority,
                invocationID: invocationID,
                expectedRevision: expectedRevision
            )
        case let .end(callerLogicalKey, target, authority, invocationID, expectedRevision, reason):
            return try endMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                target: target,
                authority: authority,
                invocationID: invocationID,
                expectedRevision: expectedRevision,
                reason: reason
            )
        }
    }

    public func createMCPAuthored(
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID
    ) throws -> MCPAuthoredMutationReceipt {
        try validateMCPInput(callerLogicalKey: callerLogicalKey, content: content, authority: authority)
        let invocationKey = MCPInvocationKey(authority: authority, invocationID: invocationID)
        if let replay = mcpInvocationReceipts[invocationKey] { return replay }
        let key = MCPKey(callerLogicalKey: callerLogicalKey, target: target, authority: authority)
        if let recordID = mcpRecordIDs[key],
           let metadata = mcpMetadata[recordID],
           let stored = recordsByID[recordID],
           stored.record.composition.freshness != .ended,
           stored.record.composition.freshness != .superseded {
            let receipt = receipt(status: .alreadyExists, recordID: recordID, metadata: metadata)
            recordMCPReceipt(invocationKey, receipt)
            return receipt
        }
        let revision = mcpRecordIDs[key].flatMap { mcpMetadata[$0]?.revision }.map { $0 &+ 1 } ?? 1
        let recordID = RecordID()
        let incarnation = UUID()
        let record = authoredRecord(id: recordID, content: content, target: target, revision: revision)
        let publication = NormalizedPublication(
            logicalKey: mcpLogicalKey(callerLogicalKey, authority: authority),
            record: record,
            transition: .semanticChange,
            isMeaningful: true
        )
        guard apply(publication) else {
            let fallback = MCPMetadata(key: key, incarnation: incarnation, revision: revision)
            let receipt = receipt(status: .alreadyExists, recordID: recordID, metadata: fallback)
            recordMCPReceipt(invocationKey, receipt)
            return receipt
        }
        generation = generation.next
        let metadata = MCPMetadata(key: key, incarnation: incarnation, revision: revision)
        mcpRecordIDs[key] = recordID
        mcpMetadata[recordID] = metadata
        let result = committedReceipt(status: .created, recordID: recordID, metadata: metadata)
        recordMCPReceipt(invocationKey, result)
        return result
    }

    public func updateMCPAuthored(
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64
    ) throws -> MCPAuthoredMutationReceipt {
        try validateMCPInput(callerLogicalKey: callerLogicalKey, content: content, authority: authority)
        let invocationKey = MCPInvocationKey(authority: authority, invocationID: invocationID)
        if let replay = mcpInvocationReceipts[invocationKey] { return replay }
        let key = MCPKey(callerLogicalKey: callerLogicalKey, target: target, authority: authority)
        guard let recordID = mcpRecordIDs[key],
              var metadata = mcpMetadata[recordID],
              let stored = recordsByID[recordID],
              stored.record.composition.freshness == .live else {
            let result = emptyReceipt(status: .notFound)
            recordMCPReceipt(invocationKey, result)
            return result
        }
        guard metadata.revision == expectedRevision else {
            let result = receipt(status: .revisionConflict, recordID: recordID, metadata: metadata)
            recordMCPReceipt(invocationKey, result)
            return result
        }
        let revision = metadata.revision &+ 1
        let record = authoredRecord(id: recordID, content: content, target: target, revision: revision)
        guard apply(NormalizedPublication(
            logicalKey: mcpLogicalKey(callerLogicalKey, authority: authority),
            record: record,
            transition: .semanticChange,
            isMeaningful: true
        )) else {
            let result = receipt(status: .revisionConflict, recordID: recordID, metadata: metadata)
            recordMCPReceipt(invocationKey, result)
            return result
        }
        generation = generation.next
        metadata.revision = revision
        mcpMetadata[recordID] = metadata
        let result = committedReceipt(status: .updated, recordID: recordID, metadata: metadata)
        recordMCPReceipt(invocationKey, result)
        return result
    }

    public func endMCPAuthored(
        callerLogicalKey: String,
        target: Target,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String
    ) throws -> MCPAuthoredMutationReceipt {
        try validateMCPAuthority(callerLogicalKey: callerLogicalKey, authority: authority)
        let invocationKey = MCPInvocationKey(authority: authority, invocationID: invocationID)
        if let replay = mcpInvocationReceipts[invocationKey] { return replay }
        let key = MCPKey(callerLogicalKey: callerLogicalKey, target: target, authority: authority)
        guard let recordID = mcpRecordIDs[key],
              var metadata = mcpMetadata[recordID],
              var stored = recordsByID[recordID],
              stored.record.composition.freshness == .live else {
            let result = emptyReceipt(status: .notFound)
            recordMCPReceipt(invocationKey, result)
            return result
        }
        guard metadata.revision == expectedRevision else {
            let result = receipt(status: .revisionConflict, recordID: recordID, metadata: metadata)
            recordMCPReceipt(invocationKey, result)
            return result
        }
        metadata.revision &+= 1
        stored.record.composition.freshness = .ended
        stored.record.detail = reason.isEmpty ? stored.record.detail : reason
        stored.record.sequence = metadata.revision
        stored.transition = .semanticChange
        stored.leaseExpiresAt = nil
        recordsByID[recordID] = stored
        mcpMetadata[recordID] = metadata
        _ = appendEvent(record: stored.record, transition: .semanticChange, meaningful: true)
        generation = generation.next
        let result = committedReceipt(status: .ended, recordID: recordID, metadata: metadata)
        recordMCPReceipt(invocationKey, result)
        return result
    }

    @discardableResult
    public func staleMCPAuthority(namespace: String) -> SurfaceSnapshot {
        var changed = false
        let orderedMetadata = mcpMetadata.sorted {
            $0.key.rawValue.uuidString.lowercased() < $1.key.rawValue.uuidString.lowercased()
        }
        for (recordID, metadata) in orderedMetadata
        where metadata.key.authority.grantInvocationNamespace == namespace {
            guard var stored = recordsByID[recordID], stored.record.composition.freshness == .live else { continue }
            stored.record.composition.freshness = .stale
            stored.usability = .staleNonactionable
            stored.transition = .leaseExpired
            stored.leaseExpiresAt = nil
            recordsByID[recordID] = stored
            _ = appendEvent(record: stored.record, transition: .leaseExpired, meaningful: true)
            changed = true
        }
        if changed { generation = generation.next }
        return makeSnapshot()
    }

    @discardableResult
    public func expireLeases() -> SurfaceSnapshot {
        let now = clock.now
        var changed = false
        let orderedRecords = recordsByID.sorted {
            $0.key.rawValue.uuidString.lowercased() < $1.key.rawValue.uuidString.lowercased()
        }
        for (recordID, var stored) in orderedRecords {
            guard stored.record.composition.freshness == .live,
                  let deadline = stored.leaseExpiresAt,
                  deadline <= now else { continue }
            stored.record.composition.freshness = .stale
            stored.usability = .staleNonactionable
            stored.transition = .leaseExpired
            stored.leaseExpiresAt = nil
            recordsByID[recordID] = stored
            _ = appendEvent(record: stored.record, transition: .leaseExpired, meaningful: true)
            changed = true
        }
        if changed { generation = generation.next }
        return makeSnapshot()
    }

    @discardableResult
    public func acknowledgeLocally(_ token: AttentionAcknowledgmentToken) -> Bool {
        guard routerReducer.acknowledgeLocally(token) else { return false }
        generation = generation.next
        _ = makeSnapshot()
        return true
    }

    @discardableResult
    public func acknowledgeDigest(_ token: DigestAcknowledgmentToken) -> DigestSnapshot {
        let current = makeSnapshot().digest
        guard !consumedDigestTokens.contains(token),
              !token.eventIDs.isEmpty,
              token.eventIDs.map(\.ordinal).max() == token.maxContiguousOrdinal else { return current }
        let knownEventIDs = Set(events.map(\.id))
        let tokenEventIDs = Set(token.eventIDs)
        guard tokenEventIDs.count == token.eventIDs.count,
              tokenEventIDs.isSubset(of: knownEventIDs) else { return current }
        acknowledgedEventIDs.formUnion(tokenEventIDs)
        consumedDigestTokens.insert(token)
        hasAcknowledgedDigest = true
        maxAcknowledgedOrdinal = max(maxAcknowledgedOrdinal ?? 0, token.maxContiguousOrdinal)
        pruneStaleState()
        generation = generation.next
        return makeSnapshot().digest
    }

    private func apply(_ publication: NormalizedPublication) -> Bool {
        let key = SupersedeKey(
            publisher: publication.record.publisher,
            logicalKey: publication.logicalKey,
            source: publication.record.source,
            target: publication.record.target
        )
        var semanticallyDistinct = true
        if let currentID = activeByKey[key], let current = recordsByID[currentID] {
            if current.record.epoch > publication.record.epoch { return false }
            if current.record.epoch == publication.record.epoch,
               current.record.sequence >= publication.record.sequence { return false }
            semanticallyDistinct = !semanticEquivalent(current.record, publication.record)
            if currentID != publication.record.id {
                var superseded = current
                superseded.record.composition.freshness = .superseded
                superseded.transition = .superseded
                superseded.leaseExpiresAt = nil
                recordsByID[currentID] = superseded
            }
        }
        if let identical = recordsByID[publication.record.id], identical.record == publication.record,
           identical.logicalKey == publication.logicalKey { return false }
        let deadline = publication.leaseDuration.flatMap { duration in
            duration > 0 ? clock.now.addingTimeInterval(duration) : nil
        }
        recordsByID[publication.record.id] = StoredRecord(
            record: publication.record,
            logicalKey: publication.logicalKey,
            usability: publication.usability,
            transition: publication.transition,
            presence: publication.presence,
            leaseExpiresAt: deadline
        )
        activeByKey[key] = publication.record.id
        if publication.isMeaningful && semanticallyDistinct {
            _ = appendEvent(
                record: publication.record,
                transition: publication.transition,
                meaningful: true
            )
            hasAcknowledgedDigest = false
        }
        return true
    }

    private func semanticEquivalent(_ lhs: NormalizedRecord, _ rhs: NormalizedRecord) -> Bool {
        var normalizedLHS = lhs
        let normalizedRHS = rhs
        normalizedLHS.id = normalizedRHS.id
        normalizedLHS.freshness = normalizedRHS.freshness
        normalizedLHS.epoch = normalizedRHS.epoch
        normalizedLHS.sequence = normalizedRHS.sequence
        return normalizedLHS == normalizedRHS
    }

    private func makeSnapshot() -> SurfaceSnapshot {
        let reduced = recordsByID.values.map { stored in
            SurfaceReducedRecord(
                record: stored.record,
                projection: eligibilityReducer.project(
                    composition: stored.record.composition,
                    usability: stored.usability,
                    transition: stored.transition,
                    presence: stored.presence,
                    isEffectiveSubject: stored.record.composition.freshness != .superseded
                ),
                effectiveSubjectID: stored.logicalKey
            )
        }
        let orderedReduced = reduced.sorted(by: BoardReducer.lessThan)
        let router = routerReducer.reduce(orderedReduced, generation: generation)
        let board = boardReducer.reduce(
            orderedReduced,
            generation: generation,
            destinationKeys: router.destinationKeys
        )
        let digest = digestReducer.reduce(
            events: events,
            records: orderedReduced,
            generation: generation,
            acknowledgedEventIDs: acknowledgedEventIDs,
            hasAcknowledgedDigest: hasAcknowledgedDigest
        )
        let activeRecords = orderedReduced.map(\.record).filter { record in
            record.composition.freshness != .superseded
                && record.composition.freshness != .ended
                && record.composition.connection != .closed(.explicit)
        }
        return SurfaceSnapshot(
            records: activeRecords,
            board: board,
            router: router,
            digest: digest,
            generation: generation
        )
    }

    @discardableResult
    private func appendEvent(
        record: NormalizedRecord,
        transition: SurfaceTransition,
        meaningful: Bool
    ) -> UInt64 {
        let ordinal = nextEventOrdinal
        nextEventOrdinal &+= 1
        events.append(SurfaceEvent(
            ordinal: ordinal,
            record: record,
            transition: transition,
            isMeaningful: meaningful,
            timestamp: clock.now
        ))
        pruneStaleState()
        return ordinal
    }

    private func recordMCPReceipt(_ key: MCPInvocationKey, _ receipt: MCPAuthoredMutationReceipt) {
        mcpInvocationReceipts[key] = receipt
        mcpInvocationReceiptDates[key] = clock.now
    }

    private func pruneStaleState() {
        let now = clock.now

        let maxAckOrdinal = maxAcknowledgedOrdinal ?? 0

        events.removeAll { event in
            let isAcknowledged = acknowledgedEventIDs.contains(event.id)
                || (maxAcknowledgedOrdinal != nil && event.ordinal <= maxAckOrdinal)
            guard isAcknowledged else { return false }
            return now.timeIntervalSince(event.timestamp) > SurfaceStore.maxRetainedEventsAge
        }

        if events.count > SurfaceStore.maxRetainedEventsCount {
            let excess = events.count - SurfaceStore.maxRetainedEventsCount
            var removed = 0
            events.removeAll { event in
                guard removed < excess else { return false }
                let isAcknowledged = acknowledgedEventIDs.contains(event.id)
                    || (maxAcknowledgedOrdinal != nil && event.ordinal <= maxAckOrdinal)
                if isAcknowledged {
                    removed += 1
                    return true
                }
                return false
            }
        }

        let remainingEventIDs = Set(events.map(\.id))
        acknowledgedEventIDs.formIntersection(remainingEventIDs)

        if consumedDigestTokens.count > SurfaceStore.maxConsumedDigestTokensCount {
            let sortedTokens = consumedDigestTokens.sorted { $0.maxContiguousOrdinal > $1.maxContiguousOrdinal }
            consumedDigestTokens = Set(sortedTokens.prefix(SurfaceStore.maxConsumedDigestTokensCount))
        }

        let activeEventRecordIDs = Set(events.map(\.record.id))
        let currentlyActiveRecordIDs = Set(activeByKey.values)

        let recordIDsToPrune = recordsByID.compactMap { (recordID, stored) -> RecordID? in
            let freshness = stored.record.composition.freshness
            let isSupersededOrEnded = (freshness == .superseded || freshness == .ended)
            guard isSupersededOrEnded else { return nil }
            guard !activeEventRecordIDs.contains(recordID) else { return nil }
            guard !currentlyActiveRecordIDs.contains(recordID) else { return nil }
            return recordID
        }

        for recordID in recordIDsToPrune {
            recordsByID.removeValue(forKey: recordID)
            mcpMetadata.removeValue(forKey: recordID)
        }

        let validRecordIDs = Set(recordsByID.keys)
        adapterRecordIDs = adapterRecordIDs.filter { validRecordIDs.contains($0.value) }
        commandRecordIDs = commandRecordIDs.filter { validRecordIDs.contains($0.value) }
        mcpRecordIDs = mcpRecordIDs.filter { validRecordIDs.contains($0.value) }
        activeByKey = activeByKey.filter { validRecordIDs.contains($0.value) }

        mcpInvocationReceiptDates = mcpInvocationReceiptDates.filter { (key, date) in
            now.timeIntervalSince(date) <= SurfaceStore.maxMCPInvocationReceiptsAge
        }
        if mcpInvocationReceipts.count > SurfaceStore.maxMCPInvocationReceiptsCount {
            let sortedKeys = mcpInvocationReceiptDates.sorted { $0.value > $1.value }.map(\.key)
            let validKeys = Set(sortedKeys.prefix(SurfaceStore.maxMCPInvocationReceiptsCount))
            mcpInvocationReceipts = mcpInvocationReceipts.filter { validKeys.contains($0.key) }
            mcpInvocationReceiptDates = mcpInvocationReceiptDates.filter { validKeys.contains($0.key) }
        } else {
            let validKeys = Set(mcpInvocationReceiptDates.keys)
            mcpInvocationReceipts = mcpInvocationReceipts.filter { validKeys.contains($0.key) }
        }
    }

    private func authoredRecord(
        id: RecordID,
        content: MCPAuthoredContent,
        target: Target,
        revision: UInt64
    ) -> NormalizedRecord {
        NormalizedRecord(
            id: id,
            kind: content.kind,
            source: .mcpAuthored,
            target: target,
            freshness: FreshnessStamp(observedAt: clock.now),
            composition: .liveLocal,
            title: content.title,
            detail: content.detail,
            agentState: content.agentState,
            epoch: generation,
            sequence: revision
        )
    }

    private func committedReceipt(
        status: MCPAuthoredMutationReceipt.Status,
        recordID: RecordID,
        metadata: MCPMetadata
    ) -> MCPAuthoredMutationReceipt {
        let commitOrdinal = nextMCPCommitOrdinal
        nextMCPCommitOrdinal &+= 1
        return MCPAuthoredMutationReceipt(
            status: status,
            recordID: recordID,
            incarnation: metadata.incarnation,
            revision: metadata.revision,
            sourceEventID: UUID(),
            commitOrdinal: commitOrdinal
        )
    }

    private func receipt(
        status: MCPAuthoredMutationReceipt.Status,
        recordID: RecordID,
        metadata: MCPMetadata
    ) -> MCPAuthoredMutationReceipt {
        MCPAuthoredMutationReceipt(
            status: status,
            recordID: recordID,
            incarnation: metadata.incarnation,
            revision: metadata.revision,
            sourceEventID: nil,
            commitOrdinal: nil
        )
    }

    private func emptyReceipt(status: MCPAuthoredMutationReceipt.Status) -> MCPAuthoredMutationReceipt {
        MCPAuthoredMutationReceipt(
            status: status,
            recordID: nil,
            incarnation: nil,
            revision: nil,
            sourceEventID: nil,
            commitOrdinal: nil
        )
    }

    private func validateMCPInput(
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        authority: MCPAuthoredAuthority
    ) throws {
        try validateMCPAuthority(callerLogicalKey: callerLogicalKey, authority: authority)
        guard !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AllwardError(
                domain: .mcp,
                operation: "author surface record",
                cause: "Title is empty",
                recovery: "Supply a bounded factual title"
            )
        }
    }

    private func validateMCPAuthority(
        callerLogicalKey: String,
        authority: MCPAuthoredAuthority
    ) throws {
        let fields = [
            callerLogicalKey,
            authority.authoritativeClientID,
            authority.grantID,
            authority.grantInvocationNamespace
        ]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AllwardError(
                domain: .mcp,
                operation: "author surface record",
                cause: "Logical key or authority identity is empty",
                recovery: "Use the authenticated grant and a non-empty caller logical key"
            )
        }
    }

    private func mcpLogicalKey(_ callerLogicalKey: String, authority: MCPAuthoredAuthority) -> String {
        [
            authority.authoritativeClientID,
            authority.grantID,
            authority.grantInvocationNamespace,
            callerLogicalKey
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func commandLogicalKey(_ commandID: String, target: Target) -> String {
        [
            target.room.rawValue.uuidString.lowercased(),
            target.session?.rawValue.uuidString.lowercased() ?? "",
            target.pane?.rawValue.uuidString.lowercased() ?? "",
            commandID
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func commandRegionLessThan(_ lhs: CommandRegionUpdate, _ rhs: CommandRegionUpdate) -> Bool {
        if lhs.commandID != rhs.commandID { return lhs.commandID < rhs.commandID }
        return lhs.phase < rhs.phase
    }

    private func adapterKey(session: AdapterSession, target: Target) -> String {
        [
            target.room.rawValue.uuidString.lowercased(),
            target.session?.rawValue.uuidString.lowercased() ?? "",
            target.pane?.rawValue.uuidString.lowercased() ?? "",
            session.id
        ].joined(separator: "|")
    }

    private func workLifecycle(for state: AgentState) -> WorkLifecycle {
        switch state {
        case .working, .blocked: .running
        case .done: .finished
        case .idle, .unknown: .none
        }
    }

    private func usabilityForAdapter(_ composition: SourceComposition) -> ComposedUsability {
        if composition.adapterHealth == .error || composition.adapterHealth == .denied {
            return .errorRecoveryOnly
        }
        return composition.control == .available ? .usableActionCapable : .usableControlDisabled
    }
}
