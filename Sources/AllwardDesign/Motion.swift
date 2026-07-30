import Foundation

/// Named, finite, damage-bounded motions (DESIGN-LANGUAGE §21). Nothing loops
/// or bounces, and the terminal grid never translates, scales, or springs.
public enum MotionToken: String, Codable, Hashable, Sendable, CaseIterable {
    /// A new actionable epoch arrived in the router.
    case routerPulse = "router-pulse"
    /// A summoned surface takes focus.
    case surfaceSummon = "surface-summon"
    /// A summoned surface returns focus to its invoker.
    case surfaceDismiss = "surface-dismiss"
    /// Focus moved to a different pane or Room.
    case targetShift = "target-shift"
    /// A tracked transition completed.
    case completionMark = "completion-mark"

    /// Duration in seconds, or `0` when Reduced Motion removes the motion.
    public func duration(reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        switch self {
        case .routerPulse: return 0.36
        case .surfaceSummon: return 0.18
        case .surfaceDismiss: return 0.14
        case .targetShift: return 0.16
        case .completionMark: return 0.24
        }
    }

    /// Reduced Motion keeps the state change but removes the animation; it
    /// never removes the information the motion carried.
    public func isAnimated(reduceMotion: Bool) -> Bool { duration(reduceMotion: reduceMotion) > 0 }
}

/// The four-earcon vocabulary (DESIGN-LANGUAGE §22). Off by default globally
/// and enabled per Room notification rules.
public enum Earcon: String, Codable, Hashable, Sendable, CaseIterable {
    /// A named user action or permission became required.
    case needsInput = "needs-input"
    /// A tracked transition completed.
    case finished
    /// An attempted operation failed.
    case error
    /// A source lost liveness and its value is retained.
    case stale

    /// Earcons are short, non-alarming, and never repeat on a timer.
    public var durationSeconds: Double {
        switch self {
        case .needsInput: 0.20
        case .finished: 0.24
        case .error: 0.28
        case .stale: 0.16
        }
    }
}
