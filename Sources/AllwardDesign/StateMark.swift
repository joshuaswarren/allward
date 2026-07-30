import AllwardCore
import Foundation

/// Every visible state colour is paired with a visible non-colour carrier
/// (DESIGN-LANGUAGE §20.1). This is that carrier: a shape name plus a label.
public struct StateMark: Hashable, Sendable {
    public var symbolName: String
    public var label: String
    public var color: ColorToken

    public init(symbolName: String, label: String, color: ColorToken) {
        self.symbolName = symbolName
        self.label = label
        self.color = color
    }

    public static func mark(for state: PresentationState) -> StateMark {
        switch state {
        case .loading:
            StateMark(symbolName: "circle.dotted", label: "Loading", color: .textSecondary)
        case .empty:
            StateMark(symbolName: "circle", label: "Empty", color: .textSecondary)
        case .live:
            StateMark(symbolName: "circle.fill", label: "Live", color: .stateRunning)
        case .needsInput:
            StateMark(
                symbolName: "exclamationmark.triangle.fill", label: "Needs input",
                color: .stateNeedsInput)
        case .running:
            StateMark(symbolName: "play.circle.fill", label: "Running", color: .stateRunning)
        case .finished:
            StateMark(
                symbolName: "checkmark.circle.fill", label: "Finished", color: .stateFinished)
        case .stale:
            StateMark(symbolName: "clock.badge.xmark", label: "Stale", color: .stateStale)
        case .degraded:
            StateMark(
                symbolName: "arrow.down.right.circle", label: "Degraded", color: .stateStale)
        case .denied:
            StateMark(symbolName: "hand.raised.fill", label: "Denied", color: .stateError)
        case .error:
            StateMark(symbolName: "xmark.octagon.fill", label: "Error", color: .stateError)
        }
    }
}
