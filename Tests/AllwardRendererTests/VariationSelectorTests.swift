import AllwardCore
import AllwardDesign
import AllwardTerminal
import CoreGraphics
import XCTest

@testable import AllwardRenderer

/// A variation selector must never make a character disappear.
///
/// U+FE0F was treated as proof that a cluster was an emoji. It is not - it asks
/// for the emoji *form* of a character that has one. herdr marks a finished
/// agent with `U+2713 U+FE0F`, and U+2713 has no emoji form, so a plain check
/// mark was sent to the colour path, no colour font covered it, and the cell
/// rendered empty. Every agent that finished showed nothing at all.
///
/// This is the general rule, not a fix for one character: any cluster whose
/// base is not an emoji keeps its text form, and selectors - which are
/// zero-width and have no glyph in any text font - are dropped before the
/// coverage check that was rejecting them.
final class VariationSelectorTests: XCTestCase {
    private func snapshot(_ text: String) -> TerminalSnapshot {
        let cells = (0 ..< 4).map { _ in TerminalCell(text: text, attributes: .default) }
        return TerminalSnapshot(
            generation: .initial,
            geometry: TerminalGeometry(columns: 4, rows: 1),
            rows: [cells],
            rowIDs: [LineID(rawValue: 1)],
            cursor: CursorState(row: 0, column: 0, visible: false, shape: .block),
            modes: TerminalModes())
    }

    private func theme() -> TerminalTheme {
        TerminalTheme(
            ansiColors: (0 ..< 16).map { _ in TokenColor(hex: "#d7dce3")! },
            defaultForeground: TokenColor(hex: "#d7dce3")!,
            defaultBackground: TokenColor(hex: "#0f1216")!,
            cursor: TokenColor(hex: "#ffc233")!,
            selectionBackground: TokenColor(hex: "#5aa0ff")!,
            selectionForeground: TokenColor(hex: "#0f1216")!,
            boldIsBright: false,
            minimumContrast: 1)
    }

    @MainActor
    private func inkFraction(_ text: String) async throws -> Double {
        let renderer = try OffscreenRenderer(
            metrics: FontMetrics.metrics(family: "Menlo", size: 13, scale: 2))
        let image = try await renderer.render(
            snapshot: snapshot(text),
            palette: DesignPalette(
                appearance: .dark, settings: .standard, contentSize: .medium),
            theme: theme())
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var inked = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let l = 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1])
                + 0.0722 * Double(data[i + 2])
            if l > 60 { inked += 1 }
        }
        return Double(inked) / Double(width * height)
    }

    /// The exact cluster herdr writes beside a finished agent.
    @MainActor
    func testACheckMarkWithAnEmojiSelectorStillDraws() async throws {
        let withSelector = try await inkFraction("\u{2713}\u{FE0F}")
        XCTAssertGreaterThan(
            withSelector, 0.005,
            "U+2713 U+FE0F drew nothing. A selector asks for a form; it must not "
                + "erase the character.")
    }

    /// And it draws the same mark as the bare character.
    @MainActor
    func testTheSelectorDoesNotChangeANonEmojiMark() async throws {
        let bare = try await inkFraction("\u{2713}")
        let selected = try await inkFraction("\u{2713}\u{FE0F}")
        XCTAssertEqual(
            selected, bare, accuracy: max(0.002, bare * 0.25),
            "The emoji selector changed a character that has no emoji form.")
    }

    /// A text-presentation selector must not erase anything either.
    @MainActor
    func testATextSelectorStillDraws() async throws {
        let inked = try await inkFraction("\u{2714}\u{FE0E}")
        XCTAssertGreaterThan(inked, 0.005, "U+2714 U+FE0E drew nothing.")
    }

    /// Real emoji keep their colour form.
    func testAnEmojiKeepsItsSelector() {
        XCTAssertEqual(FontMetrics.drawableForm(of: "\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}")
        XCTAssertEqual(FontMetrics.drawableForm(of: "\u{2713}\u{FE0F}"), "\u{2713}")
        XCTAssertEqual(FontMetrics.drawableForm(of: "\u{2714}\u{FE0E}"), "\u{2714}")
        XCTAssertEqual(FontMetrics.drawableForm(of: "a"), "a")
    }
}
