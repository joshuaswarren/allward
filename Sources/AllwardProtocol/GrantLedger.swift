import AllwardCore
import Foundation

public struct ProtocolDiagnosticCounters: Codable, Equatable, Sendable {
    public var ignoredUnknownFrame: UInt64
    public var rejectedBound: UInt64
    public var duplicateSequence: UInt64
    public var staleEpoch: UInt64

    public init(
        ignoredUnknownFrame: UInt64 = 0,
        rejectedBound: UInt64 = 0,
        duplicateSequence: UInt64 = 0,
        staleEpoch: UInt64 = 0
    ) {
        self.ignoredUnknownFrame = ignoredUnknownFrame
        self.rejectedBound = rejectedBound
        self.duplicateSequence = duplicateSequence
        self.staleEpoch = staleEpoch
    }
}

public enum PublisherLeaseState: String, Codable, Equatable, Sendable {
    case live
    case stale
    case superseded
}

public struct GrantedPublisher: Codable, Equatable, Sendable {
    public var key: PublisherTargetKey
    public var publisher: PublisherID
    public var epoch: Generation
    public var capabilities: Set<AllwardProtocolVersion.Capability>
    public var harness: String
    public var publisherName: String
    public var sessionHint: String?
    public var roomHint: String?
    public var leaseSeconds: TimeInterval
    public var grantedAt: Date
    public var leaseExpiresAt: Date

    public init(
        key: PublisherTargetKey,
        publisher: PublisherID,
        epoch: Generation,
        capabilities: Set<AllwardProtocolVersion.Capability>,
        harness: String,
        publisherName: String,
        sessionHint: String?,
        roomHint: String?,
        leaseSeconds: TimeInterval,
        grantedAt: Date,
        leaseExpiresAt: Date
    ) {
        self.key = key
        self.publisher = publisher
        self.epoch = epoch
        self.capabilities = capabilities
        self.harness = harness
        self.publisherName = publisherName
        self.sessionHint = sessionHint
        self.roomHint = roomHint
        self.leaseSeconds = leaseSeconds
        self.grantedAt = grantedAt
        self.leaseExpiresAt = leaseExpiresAt
    }
}

public actor GrantLedger {
    private struct PendingGrant: Sendable {
        var key: PublisherTargetKey
        var harness: String
        var publisherName: String
    }

    private struct ActiveGrant: Sendable {
        var publisher: GrantedPublisher
        var state: PublisherLeaseState
    }

    private let clock: any AllwardClock
    private let minimumLeaseSeconds: TimeInterval
    private let maximumLeaseSeconds: TimeInterval
    private let defaultLeaseSeconds: TimeInterval

    private var nextEpoch = Generation.initial.next
    private var pendingByDescriptor: [String: PendingGrant] = [:]
    private var activeByPublisher: [PublisherID: ActiveGrant] = [:]
    private var publisherByDescriptor: [String: PublisherID] = [:]
    private var diagnosticCounters = ProtocolDiagnosticCounters()

    public init(
        clock: any AllwardClock,
        minimumLeaseSeconds: TimeInterval = 1,
        maximumLeaseSeconds: TimeInterval = 300,
        defaultLeaseSeconds: TimeInterval = 30
    ) {
        precondition(minimumLeaseSeconds > 0)
        precondition(maximumLeaseSeconds >= minimumLeaseSeconds)
        precondition((minimumLeaseSeconds...maximumLeaseSeconds).contains(defaultLeaseSeconds))
        self.clock = clock
        self.minimumLeaseSeconds = minimumLeaseSeconds
        self.maximumLeaseSeconds = maximumLeaseSeconds
        self.defaultLeaseSeconds = defaultLeaseSeconds
    }

    public func mintPublisherTargetKey(
        target: Target,
        harness: String,
        publisherName: String,
        descriptor: String = UUID().uuidString,
        credentialGeneration: Generation
    ) -> PublisherTargetKey {
        let key = PublisherTargetKey(
            descriptor: descriptor,
            target: target,
            credentialGeneration: credentialGeneration
        )
        pendingByDescriptor[descriptor] = PendingGrant(
            key: key,
            harness: harness,
            publisherName: publisherName
        )
        return key
    }

    public func consume(_ request: GrantRequest) -> GrantResponse {
        guard let pending = pendingByDescriptor.removeValue(forKey: request.descriptor) else {
            return rejection("Unknown or consumed publisher grant")
        }

        guard request.protocolMajor == AllwardProtocolVersion.major else {
            return rejection("Unsupported protocol major \(request.protocolMajor)")
        }
        guard request.harness == pending.harness, request.publisherName == pending.publisherName else {
            return rejection("Publisher identity does not match the consumed grant")
        }

        if let existingPublisher = publisherByDescriptor[pending.key.descriptor],
           var existing = activeByPublisher[existingPublisher] {
            existing.state = .superseded
            activeByPublisher[existingPublisher] = existing
        }

        let now = clock.now
        let lease = boundedLease(request.requestedLeaseSeconds)
        let publisherID = PublisherID()
        let epoch = nextEpoch
        nextEpoch = nextEpoch.next
        let granted = GrantedPublisher(
            key: pending.key,
            publisher: publisherID,
            epoch: epoch,
            capabilities: Set(request.capabilities),
            harness: request.harness,
            publisherName: request.publisherName,
            sessionHint: request.sessionHint,
            roomHint: request.roomHint,
            leaseSeconds: lease,
            grantedAt: now,
            leaseExpiresAt: now.addingTimeInterval(lease)
        )
        activeByPublisher[publisherID] = ActiveGrant(publisher: granted, state: .live)
        publisherByDescriptor[pending.key.descriptor] = publisherID

        return GrantResponse(
            accepted: true,
            publisher: publisherID,
            epoch: epoch,
            leaseSeconds: lease,
            acceptedCapabilities: request.capabilities
        )
    }

    public func activePublisher(for descriptor: String) -> GrantedPublisher? {
        guard let publisherID = publisherByDescriptor[descriptor] else { return nil }
        return currentGrant(for: publisherID)
    }

    public func activePublisher(id: PublisherID) -> GrantedPublisher? {
        currentGrant(for: id)
    }

    public func leaseState(for publisherID: PublisherID) -> PublisherLeaseState? {
        refreshLeaseState(for: publisherID)
        return activeByPublisher[publisherID]?.state
    }

    public func admits(_ publication: PublicationFrame, from publisherID: PublisherID) -> Bool {
        refreshLeaseState(for: publisherID)
        guard let active = activeByPublisher[publisherID], active.state == .live else { return false }
        guard publication.epoch == active.publisher.epoch else {
            diagnosticCounters.staleEpoch &+= 1
            return false
        }
        return true
    }

    public func renewLease(for publisherID: PublisherID, epoch: Generation) -> Bool {
        refreshLeaseState(for: publisherID)
        guard var active = activeByPublisher[publisherID], active.state == .live else { return false }
        guard active.publisher.epoch == epoch else {
            diagnosticCounters.staleEpoch &+= 1
            return false
        }
        active.publisher.leaseExpiresAt = clock.now.addingTimeInterval(active.publisher.leaseSeconds)
        activeByPublisher[publisherID] = active
        return true
    }

    public func markDisconnected(_ publisherID: PublisherID) {
        guard var active = activeByPublisher[publisherID], active.state == .live else { return }
        active.state = .stale
        activeByPublisher[publisherID] = active
    }

    public func noteIgnoredUnknownFrame(count: UInt64 = 1) {
        diagnosticCounters.ignoredUnknownFrame &+= count
    }

    public func noteRejectedBound(count: UInt64 = 1) {
        diagnosticCounters.rejectedBound &+= count
    }

    public func noteDuplicateSequence(count: UInt64 = 1) {
        diagnosticCounters.duplicateSequence &+= count
    }

    public func noteStaleEpoch(count: UInt64 = 1) {
        diagnosticCounters.staleEpoch &+= count
    }

    public func counters() -> ProtocolDiagnosticCounters {
        diagnosticCounters
    }

    private func currentGrant(for publisherID: PublisherID) -> GrantedPublisher? {
        refreshLeaseState(for: publisherID)
        guard let active = activeByPublisher[publisherID], active.state != .superseded else { return nil }
        return active.publisher
    }

    private func refreshLeaseState(for publisherID: PublisherID) {
        guard var active = activeByPublisher[publisherID], active.state == .live else { return }
        if clock.now >= active.publisher.leaseExpiresAt {
            active.state = .stale
            activeByPublisher[publisherID] = active
        }
    }

    private func boundedLease(_ requested: TimeInterval?) -> TimeInterval {
        min(max(requested ?? defaultLeaseSeconds, minimumLeaseSeconds), maximumLeaseSeconds)
    }

    private func rejection(_ reason: String) -> GrantResponse {
        GrantResponse(
            accepted: false,
            publisher: nil,
            epoch: .initial,
            leaseSeconds: 0,
            acceptedCapabilities: [],
            rejectionReason: reason
        )
    }
}
