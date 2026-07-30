import Foundation

public enum MutationLedgerError: Error, Equatable, Sendable {
    case resultTypeMismatch(expected: String, recorded: String)
    case encodingFailed
    case decodingFailed
}

public actor MutationLedger {
    private struct Entry {
        var typeName: String
        var payload: Data
        var recordedAt: ContinuousClock.Instant
        var order: UInt64
    }

    private let maximumEntries: Int
    private let retention: Duration
    private let clock = ContinuousClock()
    private var entries: [IdempotencyKey: Entry] = [:]
    private var inFlight: [IdempotencyKey: [CheckedContinuation<Entry, Never>]] = [:]
    private var nextOrder: UInt64 = 0

    public init(maximumEntries: Int = 2_048, retention: Duration = .seconds(86_400)) {
        self.maximumEntries = max(1, maximumEntries)
        self.retention = max(.zero, retention)
    }

    public func perform<Result: Codable & Sendable>(
        key: IdempotencyKey,
        operation: @escaping @Sendable () async -> Result
    ) async throws -> Result {
        evictExpired()
        let typeName = String(reflecting: Result.self)
        if let recorded = entries[key] {
            return try decode(recorded, expectedTypeName: typeName, as: Result.self)
        }
        if inFlight[key] != nil {
            let recorded = await withCheckedContinuation { continuation in
                inFlight[key, default: []].append(continuation)
            }
            return try decode(recorded, expectedTypeName: typeName, as: Result.self)
        }

        inFlight[key] = []
        let result = await operation()
        guard let payload = try? JSONEncoder().encode(result) else {
            let failedEntry = Entry(
                typeName: typeName,
                payload: Data(),
                recordedAt: clock.now,
                order: nextOrder
            )
            let waiters = inFlight.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter.resume(returning: failedEntry) }
            throw MutationLedgerError.encodingFailed
        }
        nextOrder &+= 1
        let entry = Entry(typeName: typeName, payload: payload, recordedAt: clock.now, order: nextOrder)
        entries[key] = entry
        let waiters = inFlight.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume(returning: entry) }
        evictOverflow()
        return result
    }

    public func lookup<Result: Codable & Sendable>(
        _ key: IdempotencyKey,
        as type: Result.Type = Result.self
    ) throws -> Result? {
        evictExpired()
        guard let recorded = entries[key] else { return nil }
        return try decode(recorded, expectedTypeName: String(reflecting: type), as: type)
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private func decode<Result: Decodable>(
        _ entry: Entry,
        expectedTypeName: String,
        as type: Result.Type
    ) throws -> Result {
        guard entry.typeName == expectedTypeName else {
            throw MutationLedgerError.resultTypeMismatch(
                expected: expectedTypeName,
                recorded: entry.typeName
            )
        }
        guard let result = try? JSONDecoder().decode(type, from: entry.payload) else {
            throw MutationLedgerError.decodingFailed
        }
        return result
    }

    private func evictExpired() {
        let now = clock.now
        entries = entries.filter { _, entry in entry.recordedAt.duration(to: now) <= retention }
    }

    private func evictOverflow() {
        guard entries.count > maximumEntries else { return }
        let oldest = entries.sorted { $0.value.order < $1.value.order }
            .prefix(entries.count - maximumEntries)
        for (key, _) in oldest { entries.removeValue(forKey: key) }
    }
}
