import AllwardCore
import Foundation

/// The sole canonical mapping from technical source composition to design
/// presentation (DESIGN-LANGUAGE §18.10.1). No other type may define a second
/// presentation map, and this composer never reads eligibility output.
public enum PresentationComposer {
    public static func compose(_ source: SourceComposition) -> ComposedPresentation {
        let usability = usability(for: source)
        let controlDisabled = source.control == .unavailable
        let focusFiltered = source.focus == .denied
        let state = state(for: source)
        return ComposedPresentation(
            state: state,
            usability: usability,
            controlDisabled: controlDisabled,
            focusFiltered: focusFiltered,
            idleAccent: state == .live && source.activity == .idle
        )
    }

    // Ordered composition. Each step either returns a terminal presentation or
    // records a candidate and continues.
    private static func state(for source: SourceComposition) -> PresentationState {
        var degradedCandidate = false

        // 1. Source/operation health and applicable adapter health.
        switch source.sourceHealth {
        case .error: return .error
        case .degraded: degradedCandidate = true
        case .healthy: break
        }
        if source.adapterOwnsTarget {
            switch source.adapterHealth {
            case .error: return .error
            case .denied: return .denied
            case .degraded: degradedCandidate = true
            case .none, .available: break
            }
        }

        // 2. Connection.
        switch source.connection {
        case .idle, .resolving, .connecting, .authenticating:
            return .loading
        case .closed(.trustDenied):
            return .denied
        case .closed(.nonretryable):
            return .error
        case .closed(.explicit):
            return .empty
        case .reconnecting:
            return .stale
        case .degraded:
            degradedCandidate = true
        case .ready:
            break
        }

        // 3. Publisher lifecycle.
        switch source.publisherLifecycle {
        case .negotiating: return .loading
        case .rejected: return .denied
        case .live, .ended: break
        }

        // 4. Freshness and transition phase.
        switch source.freshness {
        case .superseded: return .empty
        case .stale: return .stale
        case .ended:
            if source.work == .finished && source.isFinishedTransitionEvent { return .finished }
            return .empty
        case .live: break
        }

        // 5. Permission/action.
        switch source.permission {
        case .active: return .needsInput
        case .expired, .denied: return .denied
        case .dismissed: return .empty
        case .granted, .none: break
        }

        // 6. Work lifecycle.
        switch source.work {
        case .finished: return .finished
        case .running: return .running
        case .none: break
        }

        // 7. Base capability.
        return degradedCandidate ? .degraded : .live
    }

    /// The usability handoff consumed by the eligibility reducer, sound, and
    /// accessibility. An error/stale/closed/unavailable result can never be
    /// re-promoted by a later permission state.
    private static func usability(for source: SourceComposition) -> ComposedUsability {
        let adapterApplies = source.adapterOwnsTarget
        let terminalError =
            source.sourceHealth == .error
            || (adapterApplies && source.adapterHealth == .error)
            || source.connection == .closed(.nonretryable)
            || source.publisherLifecycle == .rejected
            || (adapterApplies && source.adapterHealth == .denied)
        if terminalError { return .errorRecoveryOnly }

        if source.connection == .closed(.trustDenied) { return .errorRecoveryOnly }
        if source.connection == .closed(.explicit) { return .closedAbsent }
        if source.freshness == .superseded { return .closedAbsent }
        if source.connection == .reconnecting || source.freshness == .stale {
            return .staleNonactionable
        }
        if source.control == .unavailable { return .usableControlDisabled }
        return .usableActionCapable
    }
}
