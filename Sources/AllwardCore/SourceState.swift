import Foundation

// The independent technical dimensions of DESIGN-LANGUAGE §18.10.2. These are
// facts about sources, not presentation. Two consumers read them and must never
// read each other: the presentation composer (AllwardDesign) and the surface
// eligibility reducer (AllwardSurfaces). That separation is what prevents an
// authority cycle.

/// Health of an optional multiplexer adapter. `none` is normal capability
/// absence, never an error and never a call to action.
public enum AdapterHealth: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case available
    case degraded
    case denied
    case error
}

/// The reason a connection reached `closed`. The three terminal causes are
/// never collapsed into one generic failure (DESIGN-LANGUAGE §18.10.2).
public enum ConnectionCloseCause: String, Codable, Hashable, Sendable, CaseIterable {
    /// User cancelled or explicitly closed. Presents `empty`.
    case explicit
    /// Host key, credential, or policy denial. Presents `denied`.
    case trustDenied
    /// Nonretryable failure or exhausted attempt bound. Presents `error`.
    case nonretryable
}

/// Connection phase from the total transition table in SPEC §5.
public enum ConnectionState: Hashable, Sendable, Codable {
    case idle
    case resolving
    case connecting
    case authenticating
    case ready
    case degraded
    case reconnecting
    case closed(ConnectionCloseCause)

    public var isTerminal: Bool { if case .closed = self { true } else { false } }

    /// Pre-ready phases that present `loading`.
    public var isPreReady: Bool {
        switch self {
        case .idle, .resolving, .connecting, .authenticating: true
        default: false
        }
    }
}

/// Publisher handshake lifecycle (SPEC §6).
public enum PublisherLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    case negotiating
    case live
    case rejected
    case ended
}

/// Receiver-stamped freshness. Never derived from transport liveness or
/// invocation success (SPEC §6, §11).
public enum Freshness: String, Codable, Hashable, Sendable, CaseIterable {
    case live
    case stale
    case ended
    case superseded
}

/// Permission state carried by a publisher record.
public enum PermissionState: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case active
    case granted
    case denied
    case expired
    case dismissed
}

/// Semantic work lifecycle reported by a publisher.
public enum WorkLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case running
    case finished
}

/// Activity substate. `idle` is a `live` substate, never a first-class state.
public enum Activity: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case idle
}

/// Health of the source or the operation that produced a value.
public enum SourceHealth: String, Codable, Hashable, Sendable, CaseIterable {
    case healthy
    case degraded
    case error
}

/// Whether a specific control can act on this target right now.
public enum ControlCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case available
    case unavailable
}

/// Apple Focus filtering result for the owning Room.
public enum FocusFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case allowed
    case denied
}

/// The full technical input to presentation composition and eligibility.
///
/// `adapterOwnsTarget` decides whether adapter health participates at all: an
/// unrelated adapter's failure must never downgrade a local or direct-SSH pane
/// (DESIGN-LANGUAGE §18.10.1 step 1).
public struct SourceComposition: Hashable, Sendable, Codable {
    public var sourceHealth: SourceHealth
    public var adapterHealth: AdapterHealth
    public var adapterOwnsTarget: Bool
    public var connection: ConnectionState
    public var publisherLifecycle: PublisherLifecycle
    public var freshness: Freshness
    public var permission: PermissionState
    public var work: WorkLifecycle
    public var activity: Activity
    public var focus: FocusFilter
    public var control: ControlCapability
    /// True only for the single reducer-supplied finished-transition event.
    public var isFinishedTransitionEvent: Bool

    public init(
        sourceHealth: SourceHealth = .healthy,
        adapterHealth: AdapterHealth = .none,
        adapterOwnsTarget: Bool = false,
        connection: ConnectionState = .ready,
        publisherLifecycle: PublisherLifecycle = .live,
        freshness: Freshness = .live,
        permission: PermissionState = .none,
        work: WorkLifecycle = .none,
        activity: Activity = .active,
        focus: FocusFilter = .allowed,
        control: ControlCapability = .available,
        isFinishedTransitionEvent: Bool = false
    ) {
        self.sourceHealth = sourceHealth
        self.adapterHealth = adapterHealth
        self.adapterOwnsTarget = adapterOwnsTarget
        self.connection = connection
        self.publisherLifecycle = publisherLifecycle
        self.freshness = freshness
        self.permission = permission
        self.work = work
        self.activity = activity
        self.focus = focus
        self.control = control
        self.isFinishedTransitionEvent = isFinishedTransitionEvent
    }

    /// A healthy live local terminal: no adapter, no publisher, nothing to act on.
    public static let liveLocal = SourceComposition()
}

/// The composed usability handoff of DESIGN-LANGUAGE §18.10.1. Sensory and
/// eligibility consumers read this, never a raw permission in isolation.
public enum ComposedUsability: String, Codable, Hashable, Sendable, CaseIterable {
    case errorRecoveryOnly = "error-recovery-only"
    case staleNonactionable = "stale-nonactionable"
    case closedAbsent = "closed-absent"
    case usableControlDisabled = "usable-control-disabled"
    case usableActionCapable = "usable-action-capable"

    /// Whether an approval action, approval speech, or `needs-input` earcon may
    /// be offered at all.
    public var permitsApproval: Bool { self == .usableActionCapable }
}
