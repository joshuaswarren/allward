import Foundation

/// A declared attempt bound. A source that supplies no bound is a contract
/// failure: the component presents `error` with cancel, retry, and diagnostics
/// rather than remaining in `loading` forever (DESIGN-LANGUAGE §18.9).
public struct AttemptBound: Hashable, Sendable, Codable {
    public var maxAttempts: Int
    public var perAttemptTimeout: TimeInterval
    public var totalTimeout: TimeInterval

    public init(maxAttempts: Int, perAttemptTimeout: TimeInterval, totalTimeout: TimeInterval) {
        precondition(maxAttempts > 0, "an attempt bound must permit at least one attempt")
        self.maxAttempts = maxAttempts
        self.perAttemptTimeout = perAttemptTimeout
        self.totalTimeout = totalTimeout
    }

    /// Connection establishment: fail visibly rather than hang.
    public static let connect = AttemptBound(
        maxAttempts: 3, perAttemptTimeout: 20, totalTimeout: 45)
    /// Control-plane request/response on an established channel.
    public static let controlRequest = AttemptBound(
        maxAttempts: 1, perAttemptTimeout: 8, totalTimeout: 8)
    /// Bounded local work such as digest preparation.
    public static let localPrepare = AttemptBound(
        maxAttempts: 1, perAttemptTimeout: 4, totalTimeout: 4)

    /// Exponential backoff with a hard ceiling. Reconnect deadlines are the
    /// only recurring timers allowed near the transport.
    public func backoff(afterAttempt attempt: Int) -> TimeInterval {
        let base = min(pow(2.0, Double(max(0, attempt))), 30)
        return min(base, totalTimeout)
    }
}

/// The progress of one bounded operation, suitable for a `loading` label.
public struct AttemptProgress: Hashable, Sendable, Codable {
    public var attempt: Int
    public var bound: AttemptBound
    public var step: String

    public init(attempt: Int, bound: AttemptBound, step: String) {
        self.attempt = attempt
        self.bound = bound
        self.step = step
    }

    public var isExhausted: Bool { attempt >= bound.maxAttempts }

    /// The visible bounded step, e.g. `resolving host (attempt 2 of 3)`.
    public var label: String {
        bound.maxAttempts == 1 ? step : "\(step) (attempt \(attempt) of \(bound.maxAttempts))"
    }
}
