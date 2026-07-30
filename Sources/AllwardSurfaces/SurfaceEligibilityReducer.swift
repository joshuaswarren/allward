import AllwardCore
import Foundation

public enum SurfaceTransition: String, Hashable, Sendable, Codable, CaseIterable {
    case refresh
    case semanticChange
    case leaseExpired
    case reconnecting
    case explicitClose
    case superseded
    case finished

    public var isSemantic: Bool {
        switch self {
        case .semanticChange, .leaseExpired, .reconnecting, .superseded, .finished: true
        case .refresh, .explicitClose: false
        }
    }
}

public enum SurfacePresence: String, Hashable, Sendable, Codable, CaseIterable {
    case directlyOpened
    case visible
    case background
    case absent

    var permitsUnsolicitedDelivery: Bool { self == .background || self == .absent }
}

public enum SurfaceControlState: String, Hashable, Sendable, Codable, CaseIterable {
    case available
    case disabled
    case absent
}

public enum SurfaceAnnouncementLane: String, Hashable, Sendable, Codable, CaseIterable {
    case none
    case permission
    case errorRecovery
    case stale
    case degradedRecovery
    case finished
}

public struct SurfaceEligibilityProjection: Hashable, Sendable {
    public var eligibility: SurfaceEligibility
    public var boardIncluded: Bool
    public var directReadAllowed: Bool
    public var unsolicitedAllowed: Bool
    public var approvalActionAvailable: Bool
    public var controlState: SurfaceControlState
    public var announcementLane: SurfaceAnnouncementLane
    public var cancelQueuedDelivery: Bool
    public var disabledReason: String?

    public init(
        eligibility: SurfaceEligibility,
        boardIncluded: Bool,
        directReadAllowed: Bool,
        unsolicitedAllowed: Bool,
        approvalActionAvailable: Bool,
        controlState: SurfaceControlState,
        announcementLane: SurfaceAnnouncementLane,
        cancelQueuedDelivery: Bool,
        disabledReason: String? = nil
    ) {
        self.eligibility = eligibility
        self.boardIncluded = boardIncluded
        self.directReadAllowed = directReadAllowed
        self.unsolicitedAllowed = unsolicitedAllowed
        self.approvalActionAvailable = approvalActionAvailable
        self.controlState = controlState
        self.announcementLane = announcementLane
        self.cancelQueuedDelivery = cancelQueuedDelivery
        self.disabledReason = disabledReason
    }

    public static func live(record: NormalizedRecord) -> SurfaceEligibilityProjection {
        let usability: ComposedUsability = record.composition.control == .available
            ? .usableActionCapable : .usableControlDisabled
        return SurfaceEligibilityReducer().project(
            composition: record.composition,
            usability: usability,
            transition: .semanticChange,
            presence: .background,
            isEffectiveSubject: true
        )
    }
}

public struct SurfaceReducedRecord: Hashable, Sendable {
    public var record: NormalizedRecord
    public var projection: SurfaceEligibilityProjection
    public var effectiveSubjectID: String

    public init(
        record: NormalizedRecord,
        projection: SurfaceEligibilityProjection,
        effectiveSubjectID: String? = nil
    ) {
        self.record = record
        self.projection = projection
        self.effectiveSubjectID = effectiveSubjectID
            ?? record.permission?.id
            ?? record.id.rawValue.uuidString.lowercased()
    }
}

public struct SurfaceEligibilityReducer: Sendable {
    public init() {}

    public func reduce(
        composition: SourceComposition,
        usability: ComposedUsability,
        transition: SurfaceTransition,
        presence: SurfacePresence,
        isEffectiveSubject: Bool
    ) -> SurfaceEligibility {
        project(
            composition: composition,
            usability: usability,
            transition: transition,
            presence: presence,
            isEffectiveSubject: isEffectiveSubject
        ).eligibility
    }

    public func project(
        composition: SourceComposition,
        usability: ComposedUsability,
        transition: SurfaceTransition,
        presence: SurfacePresence,
        isEffectiveSubject: Bool
    ) -> SurfaceEligibilityProjection {
        let effectiveUsability = resolvedUsability(
            composition: composition,
            supplied: usability,
            transition: transition
        )
        if isAbsent(
            composition: composition,
            usability: effectiveUsability,
            transition: transition,
            isEffectiveSubject: isEffectiveSubject
        ) {
            return absentProjection(
                cancelQueuedDelivery: effectiveUsability == .closedAbsent || transition == .explicitClose
            )
        }

        let unsolicitedAllowed = composition.focus == .allowed
        let deliveryAllowed = unsolicitedAllowed && presence.permitsUnsolicitedDelivery
        let base: SurfaceEligibilityProjection
        if effectiveUsability == .errorRecoveryOnly {
            base = baseProjection(
                composition: composition,
                usability: effectiveUsability,
                transition: transition,
                deliveryAllowed: deliveryAllowed
            )
        } else if composition.connection.isPreReady || composition.publisherLifecycle == .negotiating {
            base = loadingProjection(transition: transition)
        } else if isDegraded(composition) {
            base = degradedProjection(
                composition: composition,
                transition: transition,
                deliveryAllowed: deliveryAllowed
            )
        } else {
            base = baseProjection(
                composition: composition,
                usability: effectiveUsability,
                transition: transition,
                deliveryAllowed: deliveryAllowed
            )
        }
        guard unsolicitedAllowed else {
            return SurfaceEligibilityProjection(
                eligibility: SurfaceEligibility(
                    boardActionable: base.eligibility.boardActionable,
                    routerClass: nil,
                    digestIncluded: false,
                    announcementAllowed: false,
                    earconAllowed: false
                ),
                boardIncluded: base.boardIncluded,
                directReadAllowed: base.directReadAllowed,
                unsolicitedAllowed: false,
                approvalActionAvailable: base.approvalActionAvailable,
                controlState: base.controlState,
                announcementLane: .none,
                cancelQueuedDelivery: true,
                disabledReason: base.disabledReason
            )
        }
        return base
    }

    private func isAbsent(
        composition: SourceComposition,
        usability: ComposedUsability,
        transition: SurfaceTransition,
        isEffectiveSubject: Bool
    ) -> Bool {
        guard isEffectiveSubject else { return true }
        if usability == .closedAbsent || transition == .explicitClose || transition == .superseded { return true }
        if composition.freshness == .superseded { return true }
        if composition.permission == .dismissed || composition.permission == .granted { return true }
        if composition.freshness == .ended && !composition.isFinishedTransitionEvent { return true }
        return false
    }

    private func resolvedUsability(
        composition: SourceComposition,
        supplied: ComposedUsability,
        transition: SurfaceTransition
    ) -> ComposedUsability {
        if transition == .explicitClose || composition.connection == .closed(.explicit) {
            return .closedAbsent
        }
        if composition.sourceHealth == .error
            || (composition.adapterOwnsTarget
                && (composition.adapterHealth == .error || composition.adapterHealth == .denied))
            || composition.connection == .closed(.nonretryable)
            || composition.connection == .closed(.trustDenied)
            || composition.publisherLifecycle == .rejected {
            return .errorRecoveryOnly
        }
        if composition.freshness == .stale || composition.connection == .reconnecting {
            return .staleNonactionable
        }
        if composition.control == .unavailable {
            return .usableControlDisabled
        }
        return supplied
    }

    private func isDegraded(_ composition: SourceComposition) -> Bool {
        composition.sourceHealth == .degraded
            || composition.connection == .degraded
            || (composition.adapterOwnsTarget && composition.adapterHealth == .degraded)
    }

    private func loadingProjection(transition: SurfaceTransition) -> SurfaceEligibilityProjection {
        SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: false,
                routerClass: nil,
                digestIncluded: transition.isSemantic,
                announcementAllowed: false,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: .disabled,
            announcementLane: .none,
            cancelQueuedDelivery: true,
            disabledReason: "Source is not ready"
        )
    }

    private func degradedProjection(
        composition: SourceComposition,
        transition: SurfaceTransition,
        deliveryAllowed: Bool
    ) -> SurfaceEligibilityProjection {
        let recoveryAvailable = composition.control == .available
        let semantic = transition.isSemantic
        return SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: recoveryAvailable,
                routerClass: .stale,
                digestIncluded: semantic,
                announcementAllowed: deliveryAllowed && semantic,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: recoveryAvailable ? .available : .disabled,
            announcementLane: deliveryAllowed && semantic ? .degradedRecovery : .none,
            cancelQueuedDelivery: true,
            disabledReason: recoveryAvailable ? nil : "Capability recovery unavailable"
        )
    }

    private func baseProjection(
        composition: SourceComposition,
        usability: ComposedUsability,
        transition: SurfaceTransition,
        deliveryAllowed: Bool
    ) -> SurfaceEligibilityProjection {
        switch usability {
        case .errorRecoveryOnly:
            errorProjection(composition: composition, transition: transition, deliveryAllowed: deliveryAllowed)
        case .staleNonactionable:
            staleProjection(transition: transition, deliveryAllowed: deliveryAllowed)
        case .closedAbsent:
            absentProjection(cancelQueuedDelivery: true)
        case .usableControlDisabled:
            disabledProjection(composition: composition, transition: transition)
        case .usableActionCapable:
            liveProjection(composition: composition, transition: transition, deliveryAllowed: deliveryAllowed)
        }
    }

    private func errorProjection(
        composition: SourceComposition,
        transition: SurfaceTransition,
        deliveryAllowed: Bool
    ) -> SurfaceEligibilityProjection {
        let recoveryAvailable = composition.control == .available
        let semantic = transition.isSemantic
        return SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: recoveryAvailable,
                routerClass: .error,
                digestIncluded: semantic,
                announcementAllowed: deliveryAllowed && semantic,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: recoveryAvailable ? .available : .disabled,
            announcementLane: deliveryAllowed && semantic ? .errorRecovery : .none,
            cancelQueuedDelivery: true,
            disabledReason: recoveryAvailable ? nil : "Recovery control unavailable"
        )
    }

    private func staleProjection(
        transition: SurfaceTransition,
        deliveryAllowed: Bool
    ) -> SurfaceEligibilityProjection {
        let announcesStale = transition == .leaseExpired || transition == .reconnecting
        return SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: false,
                routerClass: .stale,
                digestIncluded: transition.isSemantic,
                announcementAllowed: deliveryAllowed && announcesStale,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: .disabled,
            announcementLane: deliveryAllowed && announcesStale ? .stale : .none,
            cancelQueuedDelivery: true,
            disabledReason: "Source is stale"
        )
    }

    private func disabledProjection(
        composition: SourceComposition,
        transition: SurfaceTransition
    ) -> SurfaceEligibilityProjection {
        SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: false,
                routerClass: composition.permission == .active ? nil : lifecycleClass(composition.work),
                digestIncluded: transition.isSemantic,
                announcementAllowed: false,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: .disabled,
            announcementLane: .none,
            cancelQueuedDelivery: true,
            disabledReason: "Control unavailable"
        )
    }

    private func liveProjection(
        composition: SourceComposition,
        transition: SurfaceTransition,
        deliveryAllowed: Bool
    ) -> SurfaceEligibilityProjection {
        let semantic = transition.isSemantic
        if composition.permission == .active {
            return SurfaceEligibilityProjection(
                eligibility: SurfaceEligibility(
                    boardActionable: true,
                    routerClass: .needsInput,
                    digestIncluded: semantic,
                    announcementAllowed: deliveryAllowed && semantic,
                    earconAllowed: deliveryAllowed && semantic
                ),
                boardIncluded: true,
                directReadAllowed: true,
                unsolicitedAllowed: true,
                approvalActionAvailable: true,
                controlState: .available,
                announcementLane: deliveryAllowed && semantic ? .permission : .none,
                cancelQueuedDelivery: false
            )
        }
        if composition.permission == .expired || composition.permission == .denied {
            return SurfaceEligibilityProjection(
                eligibility: SurfaceEligibility(
                    boardActionable: false,
                    routerClass: nil,
                    digestIncluded: semantic,
                    announcementAllowed: false,
                    earconAllowed: false
                ),
                boardIncluded: true,
                directReadAllowed: true,
                unsolicitedAllowed: true,
                approvalActionAvailable: false,
                controlState: .disabled,
                announcementLane: .none,
                cancelQueuedDelivery: true,
                disabledReason: "Permission is not active"
            )
        }
        let routerClass = lifecycleClass(composition.work)
        let lane: SurfaceAnnouncementLane = composition.work == .finished && semantic ? .finished : .none
        return SurfaceEligibilityProjection(
            eligibility: SurfaceEligibility(
                boardActionable: false,
                routerClass: routerClass,
                digestIncluded: semantic,
                announcementAllowed: deliveryAllowed && lane != .none,
                earconAllowed: false
            ),
            boardIncluded: true,
            directReadAllowed: true,
            unsolicitedAllowed: true,
            approvalActionAvailable: false,
            controlState: .absent,
            announcementLane: deliveryAllowed ? lane : .none,
            cancelQueuedDelivery: false
        )
    }

    private func lifecycleClass(_ work: WorkLifecycle) -> AttentionClass? {
        switch work {
        case .running: .running
        case .finished: .finished
        case .none: nil
        }
    }

    private func absentProjection(cancelQueuedDelivery: Bool) -> SurfaceEligibilityProjection {
        SurfaceEligibilityProjection(
            eligibility: .inert,
            boardIncluded: false,
            directReadAllowed: false,
            unsolicitedAllowed: false,
            approvalActionAvailable: false,
            controlState: .absent,
            announcementLane: .none,
            cancelQueuedDelivery: cancelQueuedDelivery
        )
    }
}
