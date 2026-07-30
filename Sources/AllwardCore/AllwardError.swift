import Foundation

/// A typed, bounded failure. Diagnostics never carry unbounded terminal
/// content, secret material, or publisher payloads (SPEC §3, §14).
public struct AllwardError: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Domain: String, Codable, Hashable, Sendable, CaseIterable {
        case parser
        case transport
        case adapter
        case publisher
        case config
        case control
        case speech
        case intelligence
        case render
        case mcp
        case concierge
    }

    /// Whether retrying the same operation could plausibly succeed. This drives
    /// the `error` vs `stale` split in presentation composition.
    public enum Retryability: String, Codable, Hashable, Sendable, CaseIterable {
        case retryable
        case nonretryable
        case trustDenied
        case cancelled
    }

    public var domain: Domain
    public var operation: String
    public var cause: String
    public var retryability: Retryability
    public var recovery: String

    public init(
        domain: Domain,
        operation: String,
        cause: String,
        retryability: Retryability = .nonretryable,
        recovery: String
    ) {
        self.domain = domain
        self.operation = operation
        self.cause = Self.bounded(cause)
        self.retryability = retryability
        self.recovery = recovery
    }

    /// Diagnostics are clamped so a runaway payload can never reach a label,
    /// a log line, or an accessibility announcement.
    public static let maximumCauseLength = 240

    private static func bounded(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard collapsed.count > maximumCauseLength else { return collapsed }
        return String(collapsed.prefix(maximumCauseLength - 1)) + "\u{2026}"
    }

    public var description: String { "\(domain.rawValue): \(operation) — \(cause)" }
}
