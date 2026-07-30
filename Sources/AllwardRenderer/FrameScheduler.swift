import AppKit
import Foundation
import QuartzCore

@MainActor
public final class FrameScheduler: NSObject {
    private var displayLink: CADisplayLink?
    private var onFrame: (@MainActor () -> Void)?
    private var frameRequested = false
    private var activityDeadline: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    public init(onFrame: @escaping @MainActor () -> Void) {
        self.onFrame = onFrame
        super.init()
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(displayLinkDidFire(_:))) else {
            preconditionFailure("Allward requires an active display")
        }
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func requestFrame() {
        guard displayLink != nil else { return }
        frameRequested = true
        displayLink?.isPaused = false
    }

    public func beginFiniteActivity(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else {
            requestFrame()
            return
        }
        activityDeadline = clock.now.advanced(by: .seconds(seconds))
        displayLink?.isPaused = false
    }

    public func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
        frameRequested = false
        activityDeadline = nil
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        frameRequested = false
        onFrame?()
        if let deadline = activityDeadline, clock.now < deadline {
            return
        }
        activityDeadline = nil
        if !frameRequested {
            link.isPaused = true
        }
    }
}
