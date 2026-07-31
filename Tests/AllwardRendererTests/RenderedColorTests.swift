import AllwardCore
import AllwardDesign
import AllwardTerminal
import CoreGraphics
import XCTest

@testable import AllwardRenderer

/// Colour rules are only worth anything if they reach the pixels, so these
/// render a real cell through the same offscreen path the app and the capture
/// harness use, then read the colour back out of the bitmap.
final class RenderedColorTests: XCTestCase {
    private func snapshot(bold: Bool, foreground: TerminalColor) -> TerminalSnapshot {
        var attributes = CellAttributes.default
        attributes.foreground = foreground
        if bold { attributes.flags.insert(.bold) }
        let row = (0 ..< 8).map { _ in
            TerminalCell(text: "\u{2588}", attributes: attributes)
        }
        return TerminalSnapshot(
            generation: .initial,
            geometry: TerminalGeometry(columns: 8, rows: 1),
            rows: [row],
            rowIDs: [LineID(rawValue: 1)],
            cursor: CursorState(row: 0, column: 0, visible: false, shape: .block),
            modes: TerminalModes())
    }

    private func theme(boldIsBright: Bool, minimumContrast: Double = 1) -> TerminalTheme {
        var palette: [TokenColor] = []
        for index in 0 ..< 16 {
            palette.append(index == 1 ? TokenColor(hex: "#d66b6b")! : TokenColor(hex: "#ef8585")!)
        }
        return TerminalTheme(
            ansiColors: palette,
            defaultForeground: TokenColor(hex: "#c8cdd4")!,
            defaultBackground: TokenColor(hex: "#15191e")!,
            cursor: TokenColor(hex: "#d4a95d")!,
            selectionBackground: TokenColor(hex: "#6f9ed6")!,
            selectionForeground: TokenColor(hex: "#15191e")!,
            boldIsBright: boldIsBright,
            minimumContrast: minimumContrast)
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// Mean brightness of the whole frame. Near-black text on a near-black
    /// background has no "ink" to isolate, which is the entire point of the
    /// contrast floor, so the measure has to include every pixel.
    private func meanBrightness(_ image: CGImage) throws -> Double {
        let data = try pixels(of: image)
        var total = 0
        for index in stride(from: 0, to: data.count, by: 4) {
            total += Int(data[index]) + Int(data[index + 1]) + Int(data[index + 2])
        }
        return Double(total) / Double(data.count / 4 * 3)
    }

    /// The most saturated colour in the rendered bitmap, which for a row of
    /// full blocks is the text colour itself.
    private func inkColor(_ image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            // Skip the background, which is the darkest thing in the frame.
            guard r + g + b > 120 else { continue }
            counts[(r << 16) | (g << 8) | b, default: 0] += 1
        }
        let top = try XCTUnwrap(counts.max { $0.value < $1.value }?.key)
        return ((top >> 16) & 0xff, (top >> 8) & 0xff, top & 0xff)
    }

    @MainActor
    func testBoldRendersTheNormalColourWhenTheRuleIsOff() async throws {
        let renderer = try OffscreenRenderer(
            metrics: FontMetrics.metrics(family: "Menlo", size: 13, scale: 2))
        let image = try await renderer.render(
            snapshot: snapshot(bold: true, foreground: .indexed(1)),
            palette: DesignPalette(
                appearance: .dark, settings: .standard, contentSize: .medium),
            theme: theme(boldIsBright: false))
        let ink = try inkColor(image)
        // #d66b6b
        XCTAssertEqual(ink.r, 0xd6, accuracy: 6)
        XCTAssertEqual(ink.g, 0x6b, accuracy: 6)
    }

    @MainActor
    func testBoldRendersTheBrightColourWhenTheRuleIsOn() async throws {
        let renderer = try OffscreenRenderer(
            metrics: FontMetrics.metrics(family: "Menlo", size: 13, scale: 2))
        let image = try await renderer.render(
            snapshot: snapshot(bold: true, foreground: .indexed(1)),
            palette: DesignPalette(
                appearance: .dark, settings: .standard, contentSize: .medium),
            theme: theme(boldIsBright: true))
        let ink = try inkColor(image)
        // #ef8585
        XCTAssertEqual(ink.r, 0xef, accuracy: 6)
        XCTAssertEqual(ink.g, 0x85, accuracy: 6)
    }

    @MainActor
    func testContrastFloorLiftsUnreadableTextInThePixels() async throws {
        let renderer = try OffscreenRenderer(
            metrics: FontMetrics.metrics(family: "Menlo", size: 13, scale: 2))
        let palette = DesignPalette(
            appearance: .dark, settings: .standard, contentSize: .medium)
        // Near-black text on the near-black default background.
        let invisible = TerminalColor.rgb(26, 30, 36)
        let unenforced = try await renderer.render(
            snapshot: snapshot(bold: false, foreground: invisible),
            palette: palette, theme: theme(boldIsBright: false))
        let enforced = try await renderer.render(
            snapshot: snapshot(bold: false, foreground: invisible),
            palette: palette, theme: theme(boldIsBright: false, minimumContrast: 4.5))
        let before = try meanBrightness(unenforced)
        let after = try meanBrightness(enforced)
        XCTAssertGreaterThan(
            after, before + 8,
            "the contrast floor must lift the text well away from the background")
    }
}

extension XCTestCase {
    fileprivate func XCTAssertEqual(
        _ lhs: Int, _ rhs: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(lhs - rhs), accuracy, "\(lhs) is not within \(accuracy) of \(rhs)",
            file: file, line: line)
    }
}
