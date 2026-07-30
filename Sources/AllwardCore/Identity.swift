import Foundation

/// A stable, serializable identity that does not depend on a window, process,
/// transport, or multiplexer. Every Allward identity is one of these.
///
/// Identities are opaque to presentation code: nothing may parse a raw value to
/// recover structure. Display names live beside identities, never inside them.
public protocol AllwardIdentifier: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
where RawValue == UUID {
    init(rawValue: UUID)
}

extension AllwardIdentifier {
    /// A fresh identity. Callers that need determinism inject one instead.
    public init() { self.init(rawValue: UUID()) }

    /// Short form for dense UI columns. The full value stays in accessibility
    /// labels and detail views, per DESIGN-LANGUAGE §19.3.
    public var shortLabel: String { String(rawValue.uuidString.prefix(8)) }

    public var description: String { rawValue.uuidString }
}

/// A Room: the first-class primitive binding theme, tint, hosts, adapter
/// servers, notification rules, and defaults (DECISIONS #25, #36).
public struct RoomID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One native window. A window owns exactly one Room (SPEC §2).
public struct WindowID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One tab inside a window. A tab owns one Allward split tree.
public struct TabID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One leaf of a split tree. A pane owns exactly one target and one session.
public struct PaneID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One terminal-state lifetime. A session outlives neither its pane nor its
/// parser state: closing the pane ends the session.
public struct SessionID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One connection supervised by the remote layer.
public struct ConnectionID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One external publisher of Allward-protocol frames.
public struct PublisherID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// One normalized surface record (board row, router item, digest fact source).
public struct RecordID: AllwardIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// A session-local logical line. Selection anchors and scrollback references
/// use this, never an array index that moves on append or reflow (SPEC §3).
public struct LineID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: LineID, rhs: LineID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "line#\(rawValue)" }
    public func advanced(by n: UInt64) -> LineID { LineID(rawValue: rawValue &+ n) }
}

/// A monotonically increasing coherent-state counter.
///
/// A generation is published once per coherent snapshot. Consumers compare
/// generations to reject stale work; they never compare timestamps for the same
/// purpose.
public struct Generation: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let initial = Generation(rawValue: 0)
    public var next: Generation { Generation(rawValue: rawValue &+ 1) }

    public static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "gen\(rawValue)" }
}

/// A user-authored host alias. Allward never guesses a `user@ip`: aliases come
/// from configuration and resolve through the SSH facade.
public struct HostAlias: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// The exact target an operation addresses. Cross-boundary operations carry a
/// full target plus a generation so a late reply for a superseded target can be
/// discarded rather than applied (SPEC §5, §6).
public struct Target: Codable, Hashable, Sendable, CustomStringConvertible {
    public var room: RoomID
    public var session: SessionID?
    public var pane: PaneID?

    public init(room: RoomID, session: SessionID? = nil, pane: PaneID? = nil) {
        self.room = room
        self.session = session
        self.pane = pane
    }

    public var description: String {
        var parts = ["room:\(room.shortLabel)"]
        if let session { parts.append("session:\(session.shortLabel)") }
        if let pane { parts.append("pane:\(pane.shortLabel)") }
        return parts.joined(separator: "/")
    }
}
