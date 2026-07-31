import AllwardDesign
import AllwardTerminal
import XCTest

@testable import AllwardRenderer

/// Bold-to-bright and the contrast floor both rewrite what a program asked
/// for, so each needs to be exact about when it does and does not intervene.
final class ColorRuleTests: XCTestCase {
    private func theme(boldIsBright: Bool = false, minimumContrast: Double = 1)
        -> TerminalTheme
    {
        var palette: [TokenColor] = []
        for index in 0 ..< 16 {
            let level = Double(index) / 20
            palette.append(
                index < 8
                    ? TokenColor(level, level, level)
                    : TokenColor(0.5 + level, 0.9, 0.9))
        }
        return TerminalTheme(
            ansiColors: palette,
            defaultForeground: TokenColor(0.86, 0.88, 0.90),
            defaultBackground: TokenColor(0.06, 0.07, 0.09),
            cursor: TokenColor(0.83, 0.66, 0.36),
            selectionBackground: TokenColor(0.2, 0.3, 0.4),
            selectionForeground: TokenColor(0.06, 0.07, 0.09),
            boldIsBright: boldIsBright,
            minimumContrast: minimumContrast)
    }

    func testBoldPromotesTheEightNormalSlots() {
        let bright = theme(boldIsBright: true)
        for index in UInt8(0) ..< 8 {
            XCTAssertEqual(
                bright.resolveForeground(.indexed(index), bold: true),
                bright.resolve(.indexed(index + 8)),
                "ANSI \(index) should promote to \(index + 8) when bold")
        }
    }

    func testBoldLeavesEverythingElseAlone() {
        let bright = theme(boldIsBright: true)
        // Already bright: promoting again would run off the end of the palette.
        XCTAssertEqual(
            bright.resolveForeground(.indexed(9), bold: true), bright.resolve(.indexed(9)))
        // A 256-colour index or an RGB value is an explicit request.
        XCTAssertEqual(
            bright.resolveForeground(.indexed(160), bold: true), bright.resolve(.indexed(160)))
        XCTAssertEqual(
            bright.resolveForeground(.rgb(10, 20, 30), bold: true),
            bright.resolve(.rgb(10, 20, 30)))
        XCTAssertEqual(
            bright.resolveForeground(.defaultForeground, bold: true),
            bright.defaultForeground)
    }

    func testBoldIsInertWhenTheRuleIsOff() {
        let plain = theme(boldIsBright: false)
        for index in UInt8(0) ..< 8 {
            XCTAssertEqual(
                plain.resolveForeground(.indexed(index), bold: true),
                plain.resolve(.indexed(index)))
        }
    }

    func testContrastFloorLiftsUnreadableText() {
        let enforced = theme(minimumContrast: 4.5)
        let background = TokenColor(0.06, 0.07, 0.09)
        // Near-black on near-black: the worst case a theme cannot anticipate.
        let invisible = TokenColor(0.08, 0.09, 0.11)
        XCTAssertLessThan(invisible.contrastRatio(against: background), 4.5)
        let lifted = enforced.meetingContrast(invisible, on: background)
        XCTAssertGreaterThanOrEqual(lifted.contrastRatio(against: background), 4.49)
    }

    func testContrastFloorLeavesReadableTextUntouched() {
        let enforced = theme(minimumContrast: 4.5)
        let background = TokenColor(0.06, 0.07, 0.09)
        let readable = TokenColor(0.86, 0.88, 0.90)
        XCTAssertGreaterThan(readable.contrastRatio(against: background), 4.5)
        XCTAssertEqual(enforced.meetingContrast(readable, on: background), readable)
    }

    func testContrastFloorDarkensAgainstALightBackground() {
        let enforced = theme(minimumContrast: 4.5)
        let background = TokenColor(0.95, 0.95, 0.95)
        let washedOut = TokenColor(0.88, 0.88, 0.88)
        let fixed = enforced.meetingContrast(washedOut, on: background)
        XCTAssertLessThan(fixed.relativeLuminance, washedOut.relativeLuminance)
        XCTAssertGreaterThanOrEqual(fixed.contrastRatio(against: background), 4.49)
    }

    func testContrastFloorIsOffByDefault() {
        let plain = theme()
        let background = TokenColor(0.06, 0.07, 0.09)
        let invisible = TokenColor(0.08, 0.09, 0.11)
        XCTAssertEqual(plain.meetingContrast(invisible, on: background), invisible)
    }
}
