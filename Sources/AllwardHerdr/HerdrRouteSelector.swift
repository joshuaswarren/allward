import AllwardMultiplexer
import Foundation

public struct HerdrRouteAvailability: Hashable, Sendable {
    public var fullClientProbePassed: Bool
    public var agentAttachBidirectionalProbePassed: Bool
    public var socketAvailable: Bool
    public var snapshotReadAvailable: Bool

    public init(
        fullClientProbePassed: Bool = false,
        agentAttachBidirectionalProbePassed: Bool = false,
        socketAvailable: Bool = true,
        snapshotReadAvailable: Bool = true
    ) {
        self.fullClientProbePassed = fullClientProbePassed
        self.agentAttachBidirectionalProbePassed = agentAttachBidirectionalProbePassed
        self.socketAvailable = socketAvailable
        self.snapshotReadAvailable = snapshotReadAvailable
    }
}

public struct HerdrRouteSelection: Hashable, Sendable {
    public var route: AdapterContentRoute
    public var reason: String

    public init(route: AdapterContentRoute, reason: String) {
        self.route = route
        self.reason = reason
    }

    public var persistentLabel: String? { route.persistentLabel }
}

public struct HerdrRouteSelector: Sendable {
    public init() {}

    public func select(
        isKnownAgent: Bool,
        availability: HerdrRouteAvailability,
        failedRoutes: Set<AdapterContentRoute> = []
    ) -> HerdrRouteSelection {
        if availability.fullClientProbePassed, !failedRoutes.contains(.fullClient) {
            return HerdrRouteSelection(
                route: .fullClient,
                reason: "The full remote client probe passed"
            )
        }

        if isKnownAgent,
           availability.agentAttachBidirectionalProbePassed,
           !failedRoutes.contains(.agentAttach)
        {
            return HerdrRouteSelection(
                route: .agentAttach,
                reason: fullClientReason(availability: availability, failedRoutes: failedRoutes)
            )
        }

        if availability.socketAvailable,
           availability.snapshotReadAvailable,
           !failedRoutes.contains(.readOnlySnapshot)
        {
            return HerdrRouteSelection(
                route: .readOnlySnapshot,
                reason: snapshotReason(
                    isKnownAgent: isKnownAgent,
                    availability: availability,
                    failedRoutes: failedRoutes
                )
            )
        }

        return HerdrRouteSelection(
            route: .ordinarySSH,
            reason: ordinarySSHReason(availability: availability, failedRoutes: failedRoutes)
        )
    }

    private func fullClientReason(
        availability: HerdrRouteAvailability,
        failedRoutes: Set<AdapterContentRoute>
    ) -> String {
        if failedRoutes.contains(.fullClient) {
            return "The full remote client route failed; the bidirectional agent probe passed"
        }
        if !availability.fullClientProbePassed {
            return "The full remote client probe has not passed; the bidirectional agent probe passed"
        }
        return "The bidirectional agent probe passed"
    }

    private func snapshotReason(
        isKnownAgent: Bool,
        availability: HerdrRouteAvailability,
        failedRoutes: Set<AdapterContentRoute>
    ) -> String {
        if failedRoutes.contains(.agentAttach) {
            return "The agent-only route failed; the socket snapshot API remains available"
        }
        if !isKnownAgent {
            return "The pane is not a known agent; the socket snapshot API remains available"
        }
        if !availability.agentAttachBidirectionalProbePassed {
            return "The agent attach probe has not passed; the socket snapshot API remains available"
        }
        return "Interactive routes are unavailable; the socket snapshot API remains available"
    }

    private func ordinarySSHReason(
        availability: HerdrRouteAvailability,
        failedRoutes: Set<AdapterContentRoute>
    ) -> String {
        if failedRoutes.contains(.readOnlySnapshot) {
            return "The socket snapshot route failed; ordinary SSH can still run herdr"
        }
        if !availability.socketAvailable {
            return "The herdr socket is unavailable; ordinary SSH can still run herdr"
        }
        if !availability.snapshotReadAvailable {
            return "pane.read is unavailable; ordinary SSH can still run herdr"
        }
        return "Native control routes are unavailable; ordinary SSH can still run herdr"
    }
}
