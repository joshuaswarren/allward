import AllwardCore
import Foundation

public enum NormalizedPublicationKind: String, Codable, Equatable, Sendable {
    case plan
    case sessionUpdate = "session_update"
    case permission
    case command
    case heartbeat
}

public struct NormalizedPublication: Codable, Equatable, Sendable {
    public var kind: NormalizedPublicationKind
    public var source: RecordSource
    public var plan: [PlanEntry]?
    public var sessionUpdate: SessionUpdate?
    public var permission: PermissionRequest?
    public var command: CommandRegionUpdate?
    public var epoch: Generation
    public var sequence: UInt64
    public var observedAt: Date
    public var publisher: PublisherID
    public var publisherName: String
    public var roomHint: String?
    public var sessionHint: String?

    public init(
        kind: NormalizedPublicationKind,
        source: RecordSource,
        plan: [PlanEntry]?,
        sessionUpdate: SessionUpdate?,
        permission: PermissionRequest?,
        command: CommandRegionUpdate?,
        epoch: Generation,
        sequence: UInt64,
        observedAt: Date,
        publisher: PublisherID,
        publisherName: String,
        roomHint: String?,
        sessionHint: String?
    ) {
        self.kind = kind
        self.source = source
        self.plan = plan
        self.sessionUpdate = sessionUpdate
        self.permission = permission
        self.command = command
        self.epoch = epoch
        self.sequence = sequence
        self.observedAt = observedAt
        self.publisher = publisher
        self.publisherName = publisherName
        self.roomHint = roomHint
        self.sessionHint = sessionHint
    }
}

public enum PublicationRejection: Equatable, Sendable {
    case staleEpoch
    case duplicateOrLowerSequence
    case capabilityNotGranted
    case tooManyPlanEntries
    case tooManyPermissionOptions
}

public enum PublicationNormalizationResult: Equatable, Sendable {
    case accepted(NormalizedPublication)
    case ignored(PublicationRejection)
}

public struct PublicationNormalizerCounters: Codable, Equatable, Sendable {
    public var duplicateSequence: UInt64
    public var staleEpoch: UInt64
    public var rejectedBound: UInt64

    public init(duplicateSequence: UInt64 = 0, staleEpoch: UInt64 = 0, rejectedBound: UInt64 = 0) {
        self.duplicateSequence = duplicateSequence
        self.staleEpoch = staleEpoch
        self.rejectedBound = rejectedBound
    }
}

public actor PublicationNormalizer {
    private struct PublisherEpoch: Hashable, Sendable {
        var publisher: PublisherID
        var epoch: Generation
    }

    private let clock: any AllwardClock
    private let ledger: GrantLedger?
    private var lastSequence: [PublisherEpoch: UInt64] = [:]
    private var diagnosticCounters = PublicationNormalizerCounters()

    public init(clock: any AllwardClock, ledger: GrantLedger? = nil) {
        self.clock = clock
        self.ledger = ledger
    }

    public func accept(
        _ publication: PublicationFrame,
        from grantedPublisher: GrantedPublisher,
        source: RecordSource = .publisherDirect
    ) async -> PublicationNormalizationResult {
        guard publication.epoch == grantedPublisher.epoch else {
            diagnosticCounters.staleEpoch &+= 1
            await ledger?.noteStaleEpoch()
            return .ignored(.staleEpoch)
        }

        let key = PublisherEpoch(publisher: grantedPublisher.publisher, epoch: publication.epoch)
        if let previous = lastSequence[key], publication.sequence <= previous {
            diagnosticCounters.duplicateSequence &+= 1
            await ledger?.noteDuplicateSequence()
            return .ignored(.duplicateOrLowerSequence)
        }

        let normalized: NormalizedPublication
        switch publication.payload {
        case let .plan(entries):
            guard entries.count <= FrameDecoder.maximumPlanEntries else {
                diagnosticCounters.rejectedBound &+= 1
                await ledger?.noteRejectedBound()
                return .ignored(.tooManyPlanEntries)
            }
            guard grantedPublisher.capabilities.contains(.plans) else {
                return .ignored(.capabilityNotGranted)
            }
            normalized = makePublication(
                kind: .plan,
                publication: publication,
                publisher: grantedPublisher,
                source: source,
                plan: entries
            )
        case let .sessionUpdate(update):
            guard grantedPublisher.capabilities.contains(.sessionUpdates) else {
                return .ignored(.capabilityNotGranted)
            }
            normalized = makePublication(
                kind: .sessionUpdate,
                publication: publication,
                publisher: grantedPublisher,
                source: source,
                sessionUpdate: update
            )
        case let .permissionRequest(permission):
            guard permission.options.count <= FrameDecoder.maximumPermissionOptions else {
                diagnosticCounters.rejectedBound &+= 1
                await ledger?.noteRejectedBound()
                return .ignored(.tooManyPermissionOptions)
            }
            guard grantedPublisher.capabilities.contains(.permissions) else {
                return .ignored(.capabilityNotGranted)
            }
            normalized = makePublication(
                kind: .permission,
                publication: publication,
                publisher: grantedPublisher,
                source: source,
                permission: permission
            )
        case let .commandRegion(command):
            guard grantedPublisher.capabilities.contains(.commandRegions) else {
                return .ignored(.capabilityNotGranted)
            }
            normalized = makePublication(
                kind: .command,
                publication: publication,
                publisher: grantedPublisher,
                source: source,
                command: command
            )
        case .heartbeat:
            normalized = makePublication(
                kind: .heartbeat,
                publication: publication,
                publisher: grantedPublisher,
                source: source
            )
        }

        lastSequence[key] = publication.sequence
        return .accepted(normalized)
    }

    public func counters() -> PublicationNormalizerCounters {
        diagnosticCounters
    }

    private func makePublication(
        kind: NormalizedPublicationKind,
        publication: PublicationFrame,
        publisher: GrantedPublisher,
        source: RecordSource,
        plan: [PlanEntry]? = nil,
        sessionUpdate: SessionUpdate? = nil,
        permission: PermissionRequest? = nil,
        command: CommandRegionUpdate? = nil
    ) -> NormalizedPublication {
        NormalizedPublication(
            kind: kind,
            source: source,
            plan: plan,
            sessionUpdate: sessionUpdate,
            permission: permission,
            command: command,
            epoch: publication.epoch,
            sequence: publication.sequence,
            observedAt: clock.now,
            publisher: publisher.publisher,
            publisherName: publisher.publisherName,
            roomHint: publisher.roomHint,
            sessionHint: publisher.sessionHint
        )
    }
}
