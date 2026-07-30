import AllwardCore
import AllwardProtocol
import Foundation

/// The single normalized shape every surface consumes (SPEC §8). Publisher
/// frames, adapter facts, MCP authorship, shell integration, and native OSC 133
/// all land here; no surface reads a raw frame.
public struct NormalizedRecord: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case session
        case openLoop
        case permission
        case command
        case activity
    }

    public var id: RecordID
    public var kind: Kind
    public var source: RecordSource
    public var target: Target
    /// Receiver-stamped, never derived from transport liveness.
    public var freshness: FreshnessStamp
    public var composition: SourceComposition
    /// Short, human-facing title. Never model-generated urgency.
    public var title: String
    public var detail: String?
    public var host: HostAlias?
    public var workspace: String?
    public var publisher: PublisherID?
    public var publisherName: String?
    public var plan: [PlanEntry]
    public var permission: PermissionRequest?
    public var command: CommandRegionUpdate?
    public var agentState: String?
    /// Receiver-owned ordering within one publisher epoch.
    public var epoch: Generation
    public var sequence: UInt64

    public init(
        id: RecordID = RecordID(),
        kind: Kind,
        source: RecordSource,
        target: Target,
        freshness: FreshnessStamp,
        composition: SourceComposition,
        title: String,
        detail: String? = nil,
        host: HostAlias? = nil,
        workspace: String? = nil,
        publisher: PublisherID? = nil,
        publisherName: String? = nil,
        plan: [PlanEntry] = [],
        permission: PermissionRequest? = nil,
        command: CommandRegionUpdate? = nil,
        agentState: String? = nil,
        epoch: Generation = .initial,
        sequence: UInt64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.freshness = freshness
        self.composition = composition
        self.title = title
        self.detail = detail
        self.host = host
        self.workspace = workspace
        self.publisher = publisher
        self.publisherName = publisherName
        self.plan = plan
        self.permission = permission
        self.command = command
        self.agentState = agentState
        self.epoch = epoch
        self.sequence = sequence
    }

    public var openLoopCount: Int { plan.filter(\.isOpen).count }
}

/// The attention class a router item belongs to, highest priority first.
public enum AttentionClass: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case needsInput = 0
    case error = 1
    case finished = 2
    case running = 3
    case stale = 4

    public static func < (lhs: AttentionClass, rhs: AttentionClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .error: "Error"
        case .finished: "Finished"
        case .running: "Running"
        case .stale: "Stale"
        }
    }
}

/// The eligibility tuple produced by `SurfaceEligibilityReducer`. It consumes
/// source states and the composed usability handoff, never presentation state.
public struct SurfaceEligibility: Hashable, Sendable {
    public var boardActionable: Bool
    public var routerClass: AttentionClass?
    public var digestIncluded: Bool
    public var announcementAllowed: Bool
    public var earconAllowed: Bool

    public init(
        boardActionable: Bool,
        routerClass: AttentionClass?,
        digestIncluded: Bool,
        announcementAllowed: Bool,
        earconAllowed: Bool
    ) {
        self.boardActionable = boardActionable
        self.routerClass = routerClass
        self.digestIncluded = digestIncluded
        self.announcementAllowed = announcementAllowed
        self.earconAllowed = earconAllowed
    }

    public static let inert = SurfaceEligibility(
        boardActionable: false, routerClass: nil, digestIncluded: false,
        announcementAllowed: false, earconAllowed: false)
}
