import Foundation

/// The universal state grammar of DESIGN-LANGUAGE §18.9. A component may omit
/// a state that cannot occur; it may never rename an existing meaning locally.
public enum PresentationState: String, Codable, Hashable, Sendable, CaseIterable {
    case loading
    case empty
    case live
    case needsInput = "needs-input"
    case running
    case finished
    case stale
    case degraded
    case denied
    case error

    /// `disabled` is a control substate inside a parent presentation. It never
    /// replaces the parent component state.
    public static let controlDisabled = "disabled"
}

/// The result of composing technical source states into one presentation.
///
/// Presentation, accessibility value, and the usability handoff travel together
/// in a single value so they cannot disagree.
public struct ComposedPresentation: Hashable, Sendable, Codable {
    public var state: PresentationState
    public var usability: ComposedUsability
    /// `true` when the parent presentation stays but its control cannot act.
    public var controlDisabled: Bool
    /// `true` when Focus policy filtered this Room and the record was opened
    /// directly. Presentation and readability are preserved; only unsolicited
    /// projections are masked.
    public var focusFiltered: Bool
    /// The `idle` accent inside `live`. Never a first-class state.
    public var idleAccent: Bool

    public init(
        state: PresentationState,
        usability: ComposedUsability,
        controlDisabled: Bool = false,
        focusFiltered: Bool = false,
        idleAccent: Bool = false
    ) {
        self.state = state
        self.usability = usability
        self.controlDisabled = controlDisabled
        self.focusFiltered = focusFiltered
        self.idleAccent = idleAccent
    }
}

/// The facts an accessibility value needs, per DESIGN-LANGUAGE §18.10.3.
/// Visible labels may be shorter but must preserve target, state, and reason.
public struct PresentationSubject: Hashable, Sendable {
    public var target: String
    public var reason: String?
    public var capability: String?
    public var verb: String?
    public var source: String?
    public var workKind: String?
    public var resultKind: String?
    public var failedOperation: String?
    public var recovery: String?
    public var boundedStep: String?
    public var componentName: String
    public var freshnessBucket: String?

    public init(
        componentName: String,
        target: String,
        reason: String? = nil,
        capability: String? = nil,
        verb: String? = nil,
        source: String? = nil,
        workKind: String? = nil,
        resultKind: String? = nil,
        failedOperation: String? = nil,
        recovery: String? = nil,
        boundedStep: String? = nil,
        freshnessBucket: String? = nil
    ) {
        self.componentName = componentName
        self.target = target
        self.reason = reason
        self.capability = capability
        self.verb = verb
        self.source = source
        self.workKind = workKind
        self.resultKind = resultKind
        self.failedOperation = failedOperation
        self.recovery = recovery
        self.boundedStep = boundedStep
        self.freshnessBucket = freshnessBucket
    }
}

extension ComposedPresentation {
    /// The required accessibility value for this presentation.
    public func accessibilityValue(_ subject: PresentationSubject) -> String {
        func or(_ value: String?, _ fallback: String) -> String {
            guard let value, !value.isEmpty else { return fallback }
            return value
        }
        var value: String
        switch state {
        case .loading:
            value = "Loading: \(subject.target); \(or(subject.boundedStep, "starting"))"
        case .empty:
            value = "\(subject.componentName) empty: \(or(subject.reason, "nothing to show"))"
        case .live:
            value = "\(subject.target); live"
            if idleAccent { value += "; idle" }
        case .needsInput:
            value = "Needs input: \(or(subject.verb, "review")); \(subject.target); "
                + or(subject.source, "unknown source")
        case .running:
            value = "Running: \(subject.target); \(or(subject.workKind, "work"))"
        case .finished:
            value = "Finished: \(subject.target); \(or(subject.resultKind, "completed"))"
        case .stale:
            value = "Stale: \(subject.target); \(or(subject.reason, "disconnected"))"
                + "; last received \(or(subject.freshnessBucket, "unknown"))"
        case .degraded:
            value = "Degraded: \(subject.target); missing \(or(subject.capability, "capability"))"
        case .denied:
            value = "Denied: \(subject.target); \(or(subject.reason, "policy"))"
        case .error:
            value = "Error: \(subject.target); \(or(subject.failedOperation, "operation failed"))"
                + "; \(or(subject.recovery, "retry"))"
        }
        if focusFiltered { value += "; Focus-filtered" }
        return value
    }
}
