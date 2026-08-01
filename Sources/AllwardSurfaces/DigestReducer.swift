import AllwardCore
import AllwardProtocol
import Foundation

public struct SurfaceEventID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var recordID: RecordID
    public var ordinal: UInt64

    public init(recordID: RecordID, ordinal: UInt64) {
        self.recordID = recordID
        self.ordinal = ordinal
    }

    public var description: String { "\(recordID.description)#\(ordinal)" }
}

public struct SurfaceEvent: Hashable, Sendable, Codable, Identifiable {
    public var ordinal: UInt64
    public var record: NormalizedRecord
    public var transition: SurfaceTransition
    public var isMeaningful: Bool
    public var timestamp: Date

    public var id: SurfaceEventID { SurfaceEventID(recordID: record.id, ordinal: ordinal) }

    public init(
        ordinal: UInt64,
        record: NormalizedRecord,
        transition: SurfaceTransition,
        isMeaningful: Bool,
        timestamp: Date = Date()
    ) {
        self.ordinal = ordinal
        self.record = record
        self.transition = transition
        self.isMeaningful = isMeaningful
        self.timestamp = timestamp
    }
}

public struct SurfaceSourceLink: Hashable, Sendable, Codable {
    public var recordID: RecordID
    public var source: RecordSource
    public var target: Target
    public var commandID: String?

    public init(recordID: RecordID, source: RecordSource, target: Target, commandID: String?) {
        self.recordID = recordID
        self.source = source
        self.target = target
        self.commandID = commandID
    }
}

public struct DigestFact: Hashable, Sendable, Codable, Identifiable {
    public var id: SurfaceEventID
    public var roomID: RoomID
    public var sessionID: SessionID?
    public var title: String
    public var lines: [String]
    public var freshness: FreshnessStamp
    public var sourceFreshness: Freshness
    public var staleReason: String?
    public var sourceLink: SurfaceSourceLink
    public var composition: SourceComposition

    public init(
        id: SurfaceEventID,
        roomID: RoomID,
        sessionID: SessionID?,
        title: String,
        lines: [String],
        freshness: FreshnessStamp,
        sourceFreshness: Freshness,
        staleReason: String?,
        sourceLink: SurfaceSourceLink,
        composition: SourceComposition
    ) {
        self.id = id
        self.roomID = roomID
        self.sessionID = sessionID
        self.title = title
        self.lines = lines
        self.freshness = freshness
        self.sourceFreshness = sourceFreshness
        self.staleReason = staleReason
        self.sourceLink = sourceLink
        self.composition = composition
    }
}

public struct DigestAcknowledgmentToken: Hashable, Sendable, Codable {
    public var generation: Generation
    public var eventIDs: [SurfaceEventID]
    public var maxContiguousOrdinal: UInt64

    public init(
        generation: Generation,
        eventIDs: [SurfaceEventID],
        maxContiguousOrdinal: UInt64
    ) {
        self.generation = generation
        self.eventIDs = eventIDs
        self.maxContiguousOrdinal = maxContiguousOrdinal
    }
}

public enum DigestState: Hashable, Sendable, Codable {
    case preparing
    case readyDeterministic
    case focusFiltered
    case absent
    case sourceStale
    case partialSourceError([RecordSource])
    case acknowledged
}

public struct DigestSnapshot: Hashable, Sendable, Codable {
    public var state: DigestState
    public var allowedUnseenEventCount: Int
    public var filteredEventCount: Int
    public var facts: [DigestFact]
    public var acknowledgmentToken: DigestAcknowledgmentToken?
    public var generation: Generation

    public init(
        state: DigestState,
        allowedUnseenEventCount: Int,
        filteredEventCount: Int,
        facts: [DigestFact],
        acknowledgmentToken: DigestAcknowledgmentToken?,
        generation: Generation
    ) {
        self.state = state
        self.allowedUnseenEventCount = allowedUnseenEventCount
        self.filteredEventCount = filteredEventCount
        self.facts = facts
        self.acknowledgmentToken = acknowledgmentToken
        self.generation = generation
    }

    public static let empty = DigestSnapshot(
        state: .absent,
        allowedUnseenEventCount: 0,
        filteredEventCount: 0,
        facts: [],
        acknowledgmentToken: nil,
        generation: .initial
    )
}

public struct DigestReducer: Sendable {
    public init() {}

    public func reduce(
        events: [SurfaceEvent],
        records: [SurfaceReducedRecord],
        generation: Generation,
        acknowledgedEventIDs: Set<SurfaceEventID> = [],
        preparing: Bool = false,
        hasAcknowledgedDigest: Bool = false
    ) -> DigestSnapshot {
        let recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.record.id, $0) })
        let unseen = events.filter { $0.isMeaningful && !acknowledgedEventIDs.contains($0.id) }
        let allowed = unseen.filter { event in
            guard let current = recordByID[event.record.id] else { return false }
            return digestEligible(event: event, focus: current.record.composition.focus)
        }.sorted(by: eventLessThan)
        let filteredCount = unseen.filter { event in
            guard let current = recordByID[event.record.id],
                  current.record.composition.focus == .denied else { return false }
            return digestEligible(event: event, focus: .allowed)
        }.count
        let facts = allowed.map(makeFact)
        let acknowledgmentToken = allowed.last.map {
            DigestAcknowledgmentToken(
                generation: generation,
                eventIDs: allowed.map(\.id),
                maxContiguousOrdinal: $0.ordinal
            )
        }
        let state = digestState(
            allowed: allowed,
            records: recordByID,
            filteredCount: filteredCount,
            preparing: preparing,
            hasAcknowledgedDigest: hasAcknowledgedDigest
        )
        return DigestSnapshot(
            state: state,
            allowedUnseenEventCount: allowed.count,
            filteredEventCount: filteredCount,
            facts: facts,
            acknowledgmentToken: acknowledgmentToken,
            generation: generation
        )
    }

    private func digestEligible(
        event: SurfaceEvent,
        focus: FocusFilter
    ) -> Bool {
        var composition = event.record.composition
        composition.focus = focus
        let usability: ComposedUsability = composition.control == .available
            ? .usableActionCapable : .usableControlDisabled
        let projection = SurfaceEligibilityReducer().project(
            composition: composition,
            usability: usability,
            transition: event.transition,
            presence: .background,
            isEffectiveSubject: true
        )
        return projection.eligibility.digestIncluded
    }

    private func eventLessThan(_ lhs: SurfaceEvent, _ rhs: SurfaceEvent) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        let lhsKey = canonicalKey(lhs.record)
        let rhsKey = canonicalKey(rhs.record)
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }

    private func canonicalKey(_ record: NormalizedRecord) -> [String] {
        [
            record.target.room.rawValue.uuidString.lowercased(),
            record.target.session?.rawValue.uuidString.lowercased() ?? "",
            record.target.pane?.rawValue.uuidString.lowercased() ?? "",
            record.id.rawValue.uuidString.lowercased()
        ]
    }

    private func makeFact(_ event: SurfaceEvent) -> DigestFact {
        let record = event.record
        let lines = record.detail.map {
            $0.split(whereSeparator: \.isNewline).map(String.init)
        } ?? [record.title]
        return DigestFact(
            id: event.id,
            roomID: record.target.room,
            sessionID: record.target.session,
            title: record.title,
            lines: lines,
            freshness: record.freshness,
            sourceFreshness: record.composition.freshness,
            staleReason: staleReason(for: record.composition),
            sourceLink: SurfaceSourceLink(
                recordID: record.id,
                source: record.source,
                target: record.target,
                commandID: record.command?.commandID
            ),
            composition: record.composition
        )
    }

    private func staleReason(for composition: SourceComposition) -> String? {
        if composition.connection == .reconnecting { return "Reconnecting" }
        if composition.freshness == .stale { return "Lease expired or source authority is stale" }
        return nil
    }

    private func digestState(
        allowed: [SurfaceEvent],
        records: [RecordID: SurfaceReducedRecord],
        filteredCount: Int,
        preparing: Bool,
        hasAcknowledgedDigest: Bool
    ) -> DigestState {
        if preparing { return .preparing }
        guard !allowed.isEmpty else {
            if filteredCount > 0 { return .focusFiltered }
            return hasAcknowledgedDigest ? .acknowledged : .absent
        }
        let availableSources = Set(allowed.compactMap { records[$0.record.id]?.record.source })
        let errorSources = Set(allowed.compactMap { event -> RecordSource? in
            guard let composition = records[event.record.id]?.record.composition else { return nil }
            if composition.sourceHealth == .error { return event.record.source }
            if composition.adapterOwnsTarget && composition.adapterHealth == .error { return event.record.source }
            if case .closed(.nonretryable) = composition.connection { return event.record.source }
            return nil
        })
        if !errorSources.isEmpty && errorSources != availableSources {
            return .partialSourceError(errorSources.sorted { $0.rawValue < $1.rawValue })
        }
        if allowed.contains(where: { event in
            guard let composition = records[event.record.id]?.record.composition else { return false }
            return composition.freshness == .stale || composition.connection == .reconnecting
        }) { return .sourceStale }
        return .readyDeterministic
    }
}
