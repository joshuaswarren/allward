import AllwardDesign
import XCTest

@testable import AllwardRooms

/// Contrast floors for the themes Allward ships.
///
/// The chrome palette has been pinned since the start, but nothing checked the
/// terminal themes, and the detector that should have caught it only looked at
/// three fields. A shipped theme is where a contrast regression actually
/// reaches a reader, because these are the colours programs paint text with.
final class ThemeContrastTests: XCTestCase {
    private let textFloor = 4.5
    private let uiFloor = 3.0

    /// Mirrors `TerminalPaneView.focusRingColor`, which cannot be imported here
    /// because the chrome module is Darwin-only.
    private func resolvedFocusRing(palette: DesignPalette, background: TokenColor) -> TokenColor {
        let token = palette[.strokeKeyboardFocus]
        guard token.contrastRatio(against: background) < uiFloor else { return token }
        let pole = background.relativeLuminance > 0.5 ? TokenColor(0, 0, 0) : TokenColor(1, 1, 1)
        var low = 0.0
        var high = 1.0
        for _ in 0 ..< 12 {
            let mid = (low + high) / 2
            if token.mixed(with: pole, amount: mid).contrastRatio(against: background) < uiFloor {
                low = mid
            } else {
                high = mid
            }
        }
        return token.mixed(with: pole, amount: high)
    }

    func testShippedThemesReportNoContrastIssues() {
        for theme in ThemeCatalog.builtIns {
            let issues = theme.contrastIssues()
            XCTAssertTrue(
                issues.isEmpty,
                "\(theme.name) has contrast issues: "
                    + issues.map {
                        "\($0.field) \(String(format: "%.2f", $0.ratio)):1 "
                            + "needs \($0.requiredRatio):1"
                    }.joined(separator: ", "))
        }
    }

    func testEveryTextCarryingPaletteSlotIsLegible() {
        for theme in ThemeCatalog.builtIns {
            let palette = theme.ansi + theme.brights
            for slot in TerminalTheme.textCarryingANSISlots {
                let ratio = palette[slot].contrastRatio(against: theme.background)
                XCTAssertGreaterThanOrEqual(
                    ratio, textFloor,
                    "\(theme.name) ANSI \(slot) is \(String(format: "%.2f", ratio)):1 "
                        + "against its background; text needs \(textFloor):1")
            }
        }
    }

    func testForegroundCursorAndSelectionClearTheirFloors() {
        for theme in ThemeCatalog.builtIns {
            XCTAssertGreaterThanOrEqual(
                theme.foreground.contrastRatio(against: theme.background), textFloor,
                "\(theme.name) foreground")
            if let cursor = theme.cursor {
                XCTAssertGreaterThanOrEqual(
                    cursor.contrastRatio(against: theme.background), uiFloor,
                    "\(theme.name) cursor")
            }
            if let selection = theme.selection {
                XCTAssertGreaterThanOrEqual(
                    selection.contrastRatio(against: theme.background), uiFloor,
                    "\(theme.name) selection")
            }
        }
    }

    /// The focus ring is the only thing telling a keyboard user which pane is
    /// live. It used to be painted at 0.72 alpha, which composited to 2.87:1 on
    /// the light theme and failed WCAG 1.4.11.
    func testFocusRingClearsTheFloorOnEveryThemeBackground() {
        for theme in ThemeCatalog.builtIns {
            for appearance in Appearance.allCases {
                let palette = DesignPalette(appearance: appearance, settings: .standard)
                let ratio = resolvedFocusRing(palette: palette, background: theme.background)
                    .contrastRatio(against: theme.background)
                XCTAssertGreaterThanOrEqual(
                    ratio, uiFloor,
                    "focus ring in \(appearance) is \(String(format: "%.2f", ratio)):1 "
                        + "on \(theme.name); a focus indicator needs \(uiFloor):1")
            }
        }
    }
}
