import AllwardCore
import AllwardDesign
import AllwardTerminal
import CoreGraphics
import XCTest

@testable import AllwardRenderer

/// Box drawing has to draw a line, and the line has to join the next one.
///
/// These glyphs were scaled by their *ink* to fill the cell, which is the
/// obvious reading of "fill the cell" and is wrong: a horizontal rule's ink is
/// a thin bar, so filling the cell with it produced a solid block. Every `─`
/// and `│` came out as a bar, which is what a Powerlevel10k frame is made of.
///
/// A screenshot could not settle it - two separate visual reads of the same
/// frame disagreed - so these read the pixels.
final class BoxDrawingTests: XCTestCase {
    private func row(_ text: String, columns: Int) -> TerminalSnapshot {
        let cells = (0 ..< columns).map { _ in
            TerminalCell(text: text, attributes: .default)
        }
        return TerminalSnapshot(
            generation: .initial,
            geometry: TerminalGeometry(columns: columns, rows: 1),
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

    private func luminance(_ image: CGImage) throws -> (w: Int, h: Int, value: (Int, Int) -> Double)
    {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (
            width, height,
            { x, y in
                let i = (y * width + x) * 4
                return 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1])
                    + 0.0722 * Double(data[i + 2])
            }
        )
    }

    @MainActor
    private func render(_ text: String, columns: Int = 8) async throws -> CGImage {
        let renderer = try OffscreenRenderer(
            metrics: FontMetrics.metrics(family: "Menlo", size: 13, scale: 2))
        return try await renderer.render(
            snapshot: row(text, columns: columns),
            palette: DesignPalette(
                appearance: .dark, settings: .standard, contentSize: .medium),
            theme: theme())
    }

    /// The brightest scanline of a row of `─` must be one unbroken run.
    @MainActor
    func testAHorizontalRuleIsContinuousAcrossCells() async throws {
        let image = try await render("\u{2500}")
        let (width, height, lum) = try luminance(image)
        let inked = (0 ..< height).max { a, b in
            (0 ..< width).filter { lum($0, a) > 60 }.count
                < (0 ..< width).filter { lum($0, b) > 60 }.count
        }
        let y = try XCTUnwrap(inked)
        let on = (0 ..< width).map { lum($0, y) > 60 }
        let first = try XCTUnwrap(on.firstIndex(of: true))
        let last = try XCTUnwrap(on.lastIndex(of: true))
        let holes = on[first...last].filter { !$0 }.count
        XCTAssertEqual(
            holes, 0,
            "A row of box-drawing rules has \(holes) gap pixels between cells; the line breaks.")
        XCTAssertGreaterThan(last - first, width / 2, "The rule barely spans the row.")
    }

    /// And it has to stay a line. Filling the cell turned it into a block.
    @MainActor
    func testAHorizontalRuleIsNotASolidBlock() async throws {
        let image = try await render("\u{2500}")
        let (width, height, lum) = try luminance(image)
        let inkedRows = (0 ..< height).filter { y in
            (0 ..< width).filter { lum($0, y) > 60 }.count > width / 2
        }
        XCTAssertFalse(inkedRows.isEmpty, "The rule did not draw at all.")
        XCTAssertLessThan(
            Double(inkedRows.count) / Double(height), 0.5,
            "The rule covers \(inkedRows.count) of \(height) rows - it is a block, not a line.")
    }

    /// A full block is the one glyph that really should fill its cell, so it
    /// proves the fix did not simply shrink everything.
    @MainActor
    func testAFullBlockStillFillsItsCell() async throws {
        let image = try await render("\u{2588}")
        let (width, height, lum) = try luminance(image)
        let inkedRows = (0 ..< height).filter { y in
            (0 ..< width).filter { lum($0, y) > 60 }.count > width / 2
        }
        XCTAssertGreaterThan(
            Double(inkedRows.count) / Double(height), 0.8,
            "A full block must cover its cell.")
    }
}
