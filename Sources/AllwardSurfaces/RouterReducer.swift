import AllwardCore
import AllwardProtocol
import Foundation

public enum RouterState: Hashable, Sendable, Codable {
    case loading
    case noActionableItems
    case needsInput
    case error
    case staleOnly
    case focusFiltered
    case degradedSource(RecordSource)
    case active(AttentionClass)
    case maximumContent(exactTotal: Int)
}

public struct RouterItem: Hashable, Sendable, Codable, Identifiable {
    public var id: RecordID
    public var attentionClass: AttentionClass
    public var roomID: RoomID
    public var freshness: FreshnessStamp
    public var destinationKey: String?
    public var target: Target
    public var title: String
    public var source: RecordSource
    public var composition: SourceComposition
    public var isActionable: Bool
    public var isLocallyAcknowledged: Bool
    public var epoch: AttentionEpochID?
    public var acknowledgmentToken: AttentionAcknowledgmentToken?

    public init(
        id: RecordID,
        attentionClass: AttentionClass,
        roomID: RoomID,
        freshness: FreshnessStamp,
        destinationKey: String?,
        target: Target,
        title: String,
        source: RecordSource,
        composition: SourceComposition,
        isActionable: Bool,
        isLocallyAcknowledged: Bool,
        epoch: AttentionEpochID?,
        acknowledgmentToken: AttentionAcknowledgmentToken?
    ) {
        self.id = id
        self.attentionClass = attentionClass
        self.roomID = roomID
        self.freshness = freshness
        self.destinationKey = destinationKey
        self.target = target
        self.title = title
        self.source = source
        self.composition = composition
        self.isActionable = isActionable
        self.isLocallyAcknowledged = isLocallyAcknowledged
        self.epoch = epoch
        self.acknowledgmentToken = acknowledgmentToken
    }
}

public struct RouterSnapshot: Hashable, Sendable, Codable {
    public var state: RouterState
    public var highestPriorityClass: AttentionClass?
    public var totalActionableCount: Int
    public var filteredCount: Int
    public var roomID: RoomID?
    public var freshness: FreshnessStamp?
    public var destinationKey: String?
    public var items: [RouterItem]
    public var newEpochs: [RecordID]
    public var generation: Generation

    public init(
        state: RouterState,
        highestPriorityClass: AttentionClass?,
        totalActionableCount: Int,
        filteredCount: Int,
        roomID: RoomID?,
        freshness: FreshnessStamp?,
        destinationKey: String?,
        items: [RouterItem],
        newEpochs: [RecordID],
        generation: Generation
    ) {
        self.state = state
        self.highestPriorityClass = highestPriorityClass
        self.totalActionableCount = totalActionableCount
        self.filteredCount = filteredCount
        self.roomID = roomID
        self.freshness = freshness
        self.destinationKey = destinationKey
        self.items = items
        self.newEpochs = newEpochs
        self.generation = generation
    }

    public static let empty = RouterSnapshot(
        state: .noActionableItems,
        highestPriorityClass: nil,
        totalActionableCount: 0,
        filteredCount: 0,
        roomID: nil,
        freshness: nil,
        destinationKey: nil,
        items: [],
        newEpochs: [],
        generation: .initial
    )

    public var destinationKeys: [RecordID: String] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.destinationKey.map { (item.id, $0) }
        })
    }
}

public struct RouterReducer: Sendable {
    private var attentionEpochs = AttentionEpochTracker()
    public let visibleItemLimit: Int

    public init(visibleItemLimit: Int = 200) {
        self.visibleItemLimit = max(1, visibleItemLimit)
    }

    public mutating func reduce(
        _ records: [SurfaceReducedRecord],
        generation: Generation
    ) -> RouterSnapshot {
        let newEpochs = attentionEpochs.observe(records)
        let filteredCount = records.filter {
            $0.projection.boardIncluded && !$0.projection.unsolicitedAllowed
        }.count
        let routed = records.filter {
            $0.projection.unsolicitedAllowed && $0.projection.eligibility.routerClass != nil
        }.sorted(by: Self.lessThan)
        let exactTotal = routed.count
        let visible = Array(routed.prefix(visibleItemLimit))
        let destinationKeys = Self.destinationKeys
        let items = visible.enumerated().map { offset, reduced in
            let attentionClass = reduced.projection.eligibility.routerClass ?? .running
            let locallyAcknowledged = attentionEpochs.isLocallyAcknowledged(reduced)
            let epoch = attentionEpochs.epoch(for: reduced.record.id)
            return RouterItem(
                id: reduced.record.id,
                attentionClass: attentionClass,
                roomID: reduced.record.target.room,
                freshness: reduced.record.freshness,
                destinationKey: offset < destinationKeys.count ? destinationKeys[offset] : nil,
                target: reduced.record.target,
                title: reduced.record.title,
                source: reduced.record.source,
                composition: reduced.record.composition,
                isActionable: reduced.projection.eligibility.boardActionable && !locallyAcknowledged,
                isLocallyAcknowledged: locallyAcknowledged,
                epoch: epoch,
                acknowledgmentToken: epoch.map {
                    AttentionAcknowledgmentToken(recordID: reduced.record.id, epoch: $0)
                }
            )
        }
        let totalActionable = routed.filter {
            $0.projection.eligibility.boardActionable && !attentionEpochs.isLocallyAcknowledged($0)
        }.count
        let unacknowledgedItems = items.filter { !$0.isLocallyAcknowledged }
        let selected = unacknowledgedItems.first
        let state = routerState(
            records: records,
            items: unacknowledgedItems,
            exactTotal: exactTotal,
            filteredCount: filteredCount
        )
        return RouterSnapshot(
            state: state,
            highestPriorityClass: selected?.attentionClass,
            totalActionableCount: totalActionable,
            filteredCount: filteredCount,
            roomID: selected?.roomID,
            freshness: selected?.freshness,
            destinationKey: selected?.destinationKey,
            items: items,
            newEpochs: newEpochs,
            generation: generation
        )
    }

    @discardableResult
    public mutating func acknowledgeLocally(_ token: AttentionAcknowledgmentToken) -> Bool {
        attentionEpochs.acknowledgeLocally(token)
    }

    // AttentionClass raw values are declaration order; §8 defines router priority.
    public static func priority(_ attentionClass: AttentionClass) -> Int {
        switch attentionClass {
        case .needsInput: 0
        case .error: 1
        case .stale: 2
        case .running: 3
        case .finished: 4
        }
    }

    public static func lessThan(_ lhs: SurfaceReducedRecord, _ rhs: SurfaceReducedRecord) -> Bool {
        let lhsClass = lhs.projection.eligibility.routerClass ?? .running
        let rhsClass = rhs.projection.eligibility.routerClass ?? .running
        let lhsPriority = priority(lhsClass)
        let rhsPriority = priority(rhsClass)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return canonicalKey(lhs).lexicographicallyPrecedes(canonicalKey(rhs))
    }

    private static let destinationKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    private static func canonicalKey(_ reduced: SurfaceReducedRecord) -> [String] {
        let record = reduced.record
        return [
            record.target.room.rawValue.uuidString.lowercased(),
            record.target.session?.rawValue.uuidString.lowercased() ?? "",
            record.target.pane?.rawValue.uuidString.lowercased() ?? "",
            reduced.effectiveSubjectID,
            record.id.rawValue.uuidString.lowercased()
        ]
    }

    private func routerState(
        records: [SurfaceReducedRecord],
        items: [RouterItem],
        exactTotal: Int,
        filteredCount: Int
    ) -> RouterState {
        if exactTotal > visibleItemLimit { return .maximumContent(exactTotal: exactTotal) }
        if items.isEmpty {
            if filteredCount > 0 { return .focusFiltered }
            if records.contains(where: {
                $0.record.composition.connection.isPreReady
                    || $0.record.composition.publisherLifecycle == .negotiating
            }) { return .loading }
            return .noActionableItems
        }
        let selected = items[0]
        switch selected.attentionClass {
        case .needsInput:
            return .needsInput
        case .error:
            return .error
        case .stale:
            if let degraded = records.first(where: {
                $0.record.id == selected.id && $0.projection.unsolicitedAllowed && isDegraded($0)
            }) { return .degradedSource(degraded.record.source) }
            return items.allSatisfy({ $0.attentionClass == .stale })
                ? .staleOnly : .active(.stale)
        case .running, .finished:
            return .active(selected.attentionClass)
        }
    }

    private func isDegraded(_ reduced: SurfaceReducedRecord) -> Bool {
        let composition = reduced.record.composition
        return composition.sourceHealth == .degraded
            || composition.connection == .degraded
            || (composition.adapterOwnsTarget && composition.adapterHealth == .degraded)
    }
}
