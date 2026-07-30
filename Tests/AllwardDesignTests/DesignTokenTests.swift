import AllwardCore
import XCTest

@testable import AllwardDesign

/// The token manifest carries contracts prose cannot enforce: contrast floors,
/// scale order, and the exact presentation composition. These tests enforce them.
final class DesignTokenTests: XCTestCase {
    private let appearances: [Appearance] = [.light, .dark]

    private var configurations: [AllwardDesign.AccessibilitySettings] {
        [
            AllwardDesign.AccessibilitySettings(),
            AllwardDesign.AccessibilitySettings(increaseContrast: true),
            AllwardDesign.AccessibilitySettings(reduceTransparency: true),
            AllwardDesign.AccessibilitySettings(reduceTransparency: true, increaseContrast: true),
        ]
    }

    func testNormalTextMeetsContrastFloorOnEverySurface() {
        let textTokens: [ColorToken] = [.textPrimary, .textSecondary, .textDisabled]
        let backgrounds: [ColorToken] = [.canvas, .surface, .surfaceRaised]
        for appearance in appearances {
            for settings in configurations {
                let palette = DesignPalette(appearance: appearance, settings: settings)
                for background in backgrounds {
                    for text in textTokens {
                        let ratio = palette[text].contrastRatio(against: palette[background])
                        XCTAssertGreaterThanOrEqual(
                            ratio, 4.5,
                            "\(text.rawValue) on \(background.rawValue) in \(appearance.rawValue)")
                    }
                }
            }
        }
    }

    func testStateMarksMeetNonTextContrastFloor() {
        let stateTokens: [ColorToken] = [
            .statePermission, .stateNeedsInput, .stateError, .stateStale, .stateRunning,
            .stateFinished, .stateIdle, .strokeKeyboardFocus,
        ]
        for appearance in appearances {
            for settings in configurations {
                let palette = DesignPalette(appearance: appearance, settings: settings)
                for token in stateTokens {
                    for background in [ColorToken.canvas, .surface, .surfaceRaised] {
                        let ratio = palette[token].contrastRatio(against: palette[background])
                        XCTAssertGreaterThanOrEqual(
                            ratio, 3.0,
                            "\(token.rawValue) on \(background.rawValue) in \(appearance.rawValue)")
                    }
                }
            }
        }
    }

    func testTypeScaleOrderIsPreservedAtEveryContentSize() {
        for size in ContentSizeCategory.allCases {
            let palette = DesignPalette(appearance: .dark, contentSize: size)
            let sizes = TypeToken.scaleOrder.map { palette.type($0).size }
            XCTAssertEqual(
                sizes, sizes.sorted(), "scale order broke at content size \(size.rawValue)")
        }
    }

    func testGridTypeIgnoresDynamicType() {
        let small = DesignPalette(appearance: .dark, contentSize: .small)
        let large = DesignPalette(appearance: .dark, contentSize: .accessibilityLarge)
        XCTAssertEqual(small.type(.gridBody).size, large.type(.gridBody).size)
        XCTAssertNotEqual(small.type(.uiBody).size, large.type(.uiBody).size)
    }

    func testReduceTransparencyResolvesEveryMaterialToOpaque() {
        let palette = DesignPalette(
            appearance: .dark,
            settings: AllwardDesign.AccessibilitySettings(reduceTransparency: true))
        for material in MaterialToken.allCases {
            guard case .opaque = palette.resolve(material) else {
                return XCTFail("\(material.rawValue) stayed non-opaque under Reduce Transparency")
            }
        }
        XCTAssertFalse(palette.allowsTintedMaterial)
        XCTAssertEqual(palette[.material].alpha, 0, "Room tint material must be omitted")
    }

    func testReducedMotionRemovesEveryAnimation() {
        for motion in MotionToken.allCases {
            XCTAssertGreaterThan(motion.duration(reduceMotion: false), 0)
            XCTAssertEqual(motion.duration(reduceMotion: true), 0)
            XCTAssertFalse(motion.isAnimated(reduceMotion: true))
        }
    }

    func testEveryPresentationStateHasAVisibleNonColourCarrier() {
        for state in PresentationState.allCases {
            let mark = StateMark.mark(for: state)
            XCTAssertFalse(mark.symbolName.isEmpty)
            XCTAssertFalse(mark.label.isEmpty)
        }
    }
}

/// The ordered composition of DESIGN-LANGUAGE §18.10.1, including the four
/// required usability sentinels.
final class PresentationComposerTests: XCTestCase {
    func testSourceErrorWinsOverEveryOtherDimension() {
        let composed = PresentationComposer.compose(
            SourceComposition(sourceHealth: .error, permission: .active, work: .running))
        XCTAssertEqual(composed.state, .error)
        XCTAssertEqual(composed.usability, .errorRecoveryOnly)
        XCTAssertFalse(composed.usability.permitsApproval)
    }

    func testUnrelatedAdapterErrorLeavesALocalPaneUnchanged() {
        let composed = PresentationComposer.compose(
            SourceComposition(adapterHealth: .error, adapterOwnsTarget: false))
        XCTAssertEqual(composed.state, .live)
        XCTAssertEqual(composed.usability, .usableActionCapable)
    }

    func testAdapterErrorOnAnAdapterOwnedTargetPresentsError() {
        let composed = PresentationComposer.compose(
            SourceComposition(adapterHealth: .error, adapterOwnsTarget: true))
        XCTAssertEqual(composed.state, .error)
    }

    func testConnectionCloseCausesAreDistinct() {
        XCTAssertEqual(
            PresentationComposer.compose(SourceComposition(connection: .closed(.explicit))).state,
            .empty)
        XCTAssertEqual(
            PresentationComposer.compose(SourceComposition(connection: .closed(.trustDenied)))
                .state, .denied)
        XCTAssertEqual(
            PresentationComposer.compose(SourceComposition(connection: .closed(.nonretryable)))
                .state, .error)
    }

    func testEveryPreReadyConnectionPhasePresentsLoading() {
        for connection in [ConnectionState.idle, .resolving, .connecting, .authenticating] {
            XCTAssertEqual(
                PresentationComposer.compose(SourceComposition(connection: connection)).state,
                .loading, "\(connection) should present loading")
        }
    }

    func testStalePlusActivePermissionPresentsStaleAndDisablesApproval() {
        let composed = PresentationComposer.compose(
            SourceComposition(freshness: .stale, permission: .active))
        XCTAssertEqual(composed.state, .stale)
        XCTAssertEqual(composed.usability, .staleNonactionable)
        XCTAssertFalse(composed.usability.permitsApproval)
    }

    func testEndedPlusFinishedPresentsFinishedOnlyForTheTransitionEvent() {
        let event = PresentationComposer.compose(
            SourceComposition(freshness: .ended, work: .finished, isFinishedTransitionEvent: true))
        XCTAssertEqual(event.state, .finished)
        let afterwards = PresentationComposer.compose(
            SourceComposition(freshness: .ended, work: .finished))
        XCTAssertEqual(afterwards.state, .empty)
    }

    func testLiveSourceWithUnavailableControlStaysInspectableButNotActionable() {
        let composed = PresentationComposer.compose(
            SourceComposition(permission: .active, control: .unavailable))
        XCTAssertEqual(composed.state, .needsInput)
        XCTAssertTrue(composed.controlDisabled)
        XCTAssertEqual(composed.usability, .usableControlDisabled)
        XCTAssertFalse(composed.usability.permitsApproval)
    }

    func testExplicitCloseIsAbsentRatherThanAnError() {
        let composed = PresentationComposer.compose(
            SourceComposition(connection: .closed(.explicit), permission: .active))
        XCTAssertEqual(composed.state, .empty)
        XCTAssertEqual(composed.usability, .closedAbsent)
    }

    func testSupersededRecordHoldsNoActivePresentation() {
        let composed = PresentationComposer.compose(SourceComposition(freshness: .superseded))
        XCTAssertEqual(composed.state, .empty)
        XCTAssertEqual(composed.usability, .closedAbsent)
    }

    func testIdleIsALiveSubstateAndNotAFirstClassState() {
        let composed = PresentationComposer.compose(SourceComposition(activity: .idle))
        XCTAssertEqual(composed.state, .live)
        XCTAssertTrue(composed.idleAccent)
    }

    func testFocusFilteringPreservesPresentationAndAnnotatesTheValue() {
        let composed = PresentationComposer.compose(SourceComposition(focus: .denied))
        XCTAssertEqual(composed.state, .live)
        XCTAssertTrue(composed.focusFiltered)
        let value = composed.accessibilityValue(
            PresentationSubject(componentName: "Board", target: "esper"))
        XCTAssertTrue(value.contains("Focus-filtered"))
    }

    func testAccessibilityValueNamesTargetStateAndReason() {
        let stale = PresentationComposer.compose(SourceComposition(freshness: .stale))
        let value = stale.accessibilityValue(
            PresentationSubject(
                componentName: "Board", target: "omp-a", reason: "Disconnected",
                freshnessBucket: "2m ago"))
        XCTAssertEqual(value, "Stale: omp-a; Disconnected; last received 2m ago")
    }
}
