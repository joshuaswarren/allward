import Foundation

/// Injected time. Nothing in Allward reads the wall clock directly: tests pin a
/// clock, and the freshness buckets below stay deterministic.
public protocol AllwardClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: AllwardClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock whose value is set explicitly. Used by fixtures and gate receipts.
public final class FixedClock: AllwardClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    public init(_ value: Date = Date(timeIntervalSince1970: 0)) { self.value = value }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }

    public func set(_ newValue: Date) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Bucketed freshness. Labels update only when a visible bucket boundary is
/// crossed, which is what keeps freshness timers off the polling list
/// (SPEC §4 "No polling rule and permitted timers").
public enum FreshnessBucket: Hashable, Sendable, Codable, CaseIterable {
    case now
    case seconds
    case minutes
    case hours
    case days

    public static func bucket(forAge age: TimeInterval) -> FreshnessBucket {
        switch age {
        case ..<2: .now
        case ..<60: .seconds
        case ..<3600: .minutes
        case ..<86_400: .hours
        default: .days
        }
    }

    /// Seconds until this age crosses into the next bucket, or `nil` at the
    /// coarsest bucket where no further wakeup is ever scheduled.
    public static func secondsUntilNextBoundary(forAge age: TimeInterval) -> TimeInterval? {
        switch bucket(forAge: age) {
        case .now: 2 - age
        case .seconds: 60 - age
        case .minutes: 3600 - age
        case .hours: 86_400 - age
        case .days: nil
        }
    }

    public func label(forAge age: TimeInterval) -> String {
        switch self {
        case .now: "just now"
        case .seconds: "\(Int(age.rounded(.down)))s ago"
        case .minutes: "\(Int((age / 60).rounded(.down)))m ago"
        case .hours: "\(Int((age / 3600).rounded(.down)))h ago"
        case .days: "\(Int((age / 86_400).rounded(.down)))d ago"
        }
    }
}

/// A receiver-stamped observation time plus its derived bucket.
public struct FreshnessStamp: Hashable, Sendable, Codable {
    public var observedAt: Date
    public init(observedAt: Date) { self.observedAt = observedAt }

    public func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(observedAt)) }
    public func bucket(at now: Date) -> FreshnessBucket {
        FreshnessBucket.bucket(forAge: age(at: now))
    }
    public func label(at now: Date) -> String {
        let age = age(at: now)
        return FreshnessBucket.bucket(forAge: age).label(forAge: age)
    }
}
