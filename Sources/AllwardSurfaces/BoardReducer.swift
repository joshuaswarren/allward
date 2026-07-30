import AllwardCore
import AllwardProtocol
import Foundation

public enum BoardState: Hashable, Sendable, Codable {
    case loading
    case emptyNoSessions
    case emptyNoOpenLoops
    case zeroPublishers
    case populated
    case staleOrDegraded
    case permission
    case error
    case maximumContent(exactTotal: Int)
}

public enum BoardRowState: String, Hashable, Sendable, Codable, CaseIterable {
    case loading
    case live
    case needsInput
    case running
    case finished
    case stale
    case degraded
    case denied
    case error
}

public struct BoardPublisherColumns: Hashable, Sendable, Codable {
    public var publisherID: PublisherID
    public var publisherName: String?
    public var requestVerb: String?
    public var options: [PermissionRequest.Option]
    public var expiry: Date?

    public init(
        publisherID: PublisherID,
        publisherName: String?,
        requestVerb: String?,
        options: [PermissionRequest.Option],
        expiry: Date?
    ) {
        self.publisherID = publisherID
        self.publisherName = publisherName
        self.requestVerb = requestVerb
        self.options = options
        self.expiry = expiry
    }
}

public struct BoardRow: Hashable, Sendable, Codable, Identifiable {
    public var id: RecordID
    public var roomID: RoomID
    public var host: HostAlias?
    public var workspace: String?
    public var state: BoardRowState
    public var sessionIdentity: String
    public var title: String
    public var detail: String?
    public var openLoopCount: Int
    public var freshness: FreshnessStamp
    public var destinationKey: String?
    public var target: Target
    public var source: RecordSource
    public var composition: SourceComposition
    public var publisher: BoardPublisherColumns?
    public var isActionable: Bool
    public var approvalActionAvailable: Bool
    public var disabledReason: String?

    public init(
        id: RecordID,
        roomID: RoomID,
        host: HostAlias?,
        workspace: String?,
        state: BoardRowState,
        sessionIdentity: String,
        title: String,
        detail: String?,
        openLoopCount: Int,
        freshness: FreshnessStamp,
        destinationKey: String?,
        target: Target,
        source: RecordSource,
        composition: SourceComposition,
        publisher: BoardPublisherColumns?,
        isActionable: Bool,
        approvalActionAvailable: Bool,
        disabledReason: String?
    ) {
        self.id = id
        self.roomID = roomID
        self.host = host
        self.workspace = workspace
        self.state = state
        self.sessionIdentity = sessionIdentity
        self.title = title
        self.detail = detail
        self.openLoopCount = openLoopCount
        self.freshness = freshness
        self.destinationKey = destinationKey
        self.target = target
        self.source = source
        self.composition = composition
        self.publisher = publisher
        self.isActionable = isActionable
        self.approvalActionAvailable = approvalActionAvailable
        self.disabledReason = disabledReason
    }
}

public struct BoardGroup: Hashable, Sendable, Codable, Identifiable {
    public var roomID: RoomID
    public var host: HostAlias?
    public var workspace: String?
    public var rows: [BoardRow]

    public var id: String {
        "\(roomID.rawValue.uuidString.lowercased())|\(host?.rawValue ?? "")|\(workspace ?? "")"
    }

    public init(roomID: RoomID, host: HostAlias?, workspace: String?, rows: [BoardRow]) {
        self.roomID = roomID
        self.host = host
        self.workspace = workspace
        self.rows = rows
    }
}

public struct BoardSnapshot: Hashable, Sendable, Codable {
    public var state: BoardState
    public var groups: [BoardGroup]
    public var visibleRowCount: Int
    public var exactTotal: Int
    public var generation: Generation

    public init(
        state: BoardState,
        groups: [BoardGroup],
        visibleRowCount: Int,
        exactTotal: Int,
        generation: Generation
    ) {
        self.state = state
        self.groups = groups
        self.visibleRowCount = visibleRowCount
        self.exactTotal = exactTotal
        self.generation = generation
    }

    public static let empty = BoardSnapshot(
        state: .emptyNoSessions,
        groups: [],
        visibleRowCount: 0,
        exactTotal: 0,
        generation: .initial
    )
}

public struct BoardReducer: Sendable {
    public let visibleRowLimit: Int

    public init(visibleRowLimit: Int = 200) {
        self.visibleRowLimit = max(1, visibleRowLimit)
    }

    public func reduce(
        _ records: [SurfaceReducedRecord],
        generation: Generation,
        destinationKeys: [RecordID: String] = [:]
    ) -> BoardSnapshot {
        let included = records.filter(\.projection.boardIncluded).sorted(by: Self.lessThan)
        let rows = included.map { makeRow($0, destinationKey: destinationKeys[$0.record.id]) }
        let exactTotal = rows.count
        let visibleRows = Array(rows.prefix(visibleRowLimit))
        let groups = makeGroups(visibleRows)
        let state = exactTotal > visibleRowLimit
            ? BoardState.maximumContent(exactTotal: exactTotal)
            : state(for: included)
        return BoardSnapshot(
            state: state,
            groups: groups,
            visibleRowCount: visibleRows.count,
            exactTotal: exactTotal,
            generation: generation
        )
    }

    public static func lessThan(_ lhs: SurfaceReducedRecord, _ rhs: SurfaceReducedRecord) -> Bool {
        canonicalKey(lhs).lexicographicallyPrecedes(canonicalKey(rhs))
    }

    private static func canonicalKey(_ reduced: SurfaceReducedRecord) -> [String] {
        let record = reduced.record
        return [
            record.target.room.rawValue.uuidString.lowercased(),
            record.host?.rawValue ?? "",
            record.workspace ?? "",
            record.target.session?.rawValue.uuidString.lowercased() ?? "",
            record.target.pane?.rawValue.uuidString.lowercased() ?? "",
            reduced.effectiveSubjectID,
            record.id.rawValue.uuidString.lowercased()
        ]
    }

    private func makeRow(_ reduced: SurfaceReducedRecord, destinationKey: String?) -> BoardRow {
        let record = reduced.record
        let publisher = record.publisher.map {
            BoardPublisherColumns(
                publisherID: $0,
                publisherName: record.publisherName,
                requestVerb: record.permission?.verb,
                options: record.permission?.options ?? [],
                expiry: record.permission?.expiresAt
            )
        }
        let sessionIdentity = record.target.session?.shortLabel
            ?? record.target.pane?.shortLabel
            ?? record.id.shortLabel
        return BoardRow(
            id: record.id,
            roomID: record.target.room,
            host: record.host,
            workspace: record.workspace,
            state: rowState(for: record),
            sessionIdentity: sessionIdentity,
            title: record.title,
            detail: record.detail,
            openLoopCount: record.openLoopCount,
            freshness: record.freshness,
            destinationKey: destinationKey,
            target: record.target,
            source: record.source,
            composition: record.composition,
            publisher: publisher,
            isActionable: reduced.projection.eligibility.boardActionable,
            approvalActionAvailable: reduced.projection.approvalActionAvailable,
            disabledReason: reduced.projection.disabledReason
        )
    }

    private func makeGroups(_ rows: [BoardRow]) -> [BoardGroup] {
        var groups: [BoardGroup] = []
        for row in rows {
            if let last = groups.indices.last,
               groups[last].roomID == row.roomID,
               groups[last].host == row.host,
               groups[last].workspace == row.workspace {
                groups[last].rows.append(row)
            } else {
                groups.append(BoardGroup(
                    roomID: row.roomID,
                    host: row.host,
                    workspace: row.workspace,
                    rows: [row]
                ))
            }
        }
        return groups
    }

    private func state(for records: [SurfaceReducedRecord]) -> BoardState {
        guard !records.isEmpty else { return .emptyNoSessions }
        let compositions = records.map(\.record.composition)
        if compositions.contains(where: isTerminalFailure) { return .error }
        if compositions.contains(where: { $0.connection.isPreReady || $0.publisherLifecycle == .negotiating }) {
            return .loading
        }
        if compositions.contains(where: isStaleOrDegraded) { return .staleOrDegraded }
        if compositions.contains(where: { $0.permission == .active }) { return .permission }
        if records.allSatisfy({ $0.record.publisher == nil }) { return .zeroPublishers }
        if records.allSatisfy({ $0.record.openLoopCount == 0 && $0.record.composition.permission != .active }) {
            return .emptyNoOpenLoops
        }
        return .populated
    }

    private func rowState(for record: NormalizedRecord) -> BoardRowState {
        let composition = record.composition
        if isTerminalError(composition) { return .error }
        if composition.connection.isPreReady || composition.publisherLifecycle == .negotiating { return .loading }
        if composition.freshness == .stale || composition.connection == .reconnecting { return .stale }
        if composition.sourceHealth == .degraded || composition.connection == .degraded
            || (composition.adapterOwnsTarget && composition.adapterHealth == .degraded) { return .degraded }
        if composition.permission == .denied || composition.permission == .expired
            || composition.publisherLifecycle == .rejected
            || (composition.adapterOwnsTarget && composition.adapterHealth == .denied)
            || composition.connection == .closed(.trustDenied) { return .denied }
        if composition.permission == .active { return .needsInput }
        if composition.work == .running { return .running }
        if composition.work == .finished { return .finished }
        return .live
    }

    private func isTerminalFailure(_ composition: SourceComposition) -> Bool {
        isTerminalError(composition)
            || composition.publisherLifecycle == .rejected
            || (composition.adapterOwnsTarget && composition.adapterHealth == .denied)
            || composition.connection == .closed(.trustDenied)
    }

    private func isTerminalError(_ composition: SourceComposition) -> Bool {
        if composition.sourceHealth == .error { return true }
        if composition.adapterOwnsTarget && composition.adapterHealth == .error { return true }
        if case .closed(.nonretryable) = composition.connection { return true }
        return false
    }

    private func isStaleOrDegraded(_ composition: SourceComposition) -> Bool {
        composition.freshness == .stale
            || composition.connection == .reconnecting
            || composition.connection == .degraded
            || composition.sourceHealth == .degraded
            || (composition.adapterOwnsTarget && composition.adapterHealth == .degraded)
    }
}
