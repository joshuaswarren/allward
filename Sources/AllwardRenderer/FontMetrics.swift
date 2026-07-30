import CoreGraphics
import CoreText
import Foundation

public struct CellMetrics: Hashable, Sendable {
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    public var baseline: CGFloat
    public var underlinePosition: CGFloat
    public var underlineThickness: CGFloat
    public var scale: CGFloat

    var fontFamily: String
    var pointSize: Double

    public init(
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        baseline: CGFloat,
        underlinePosition: CGFloat,
        underlineThickness: CGFloat,
        scale: CGFloat
    ) {
        precondition(cellWidth > 0 && cellHeight > 0 && scale > 0)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.baseline = baseline
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.scale = scale
        fontFamily = "SF Mono"
        pointSize = Double(cellHeight / scale)
    }

    init(
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        baseline: CGFloat,
        underlinePosition: CGFloat,
        underlineThickness: CGFloat,
        scale: CGFloat,
        fontFamily: String,
        pointSize: Double
    ) {
        self.init(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            baseline: baseline,
            underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            scale: scale
        )
        self.fontFamily = fontFamily
        self.pointSize = pointSize
    }
}

public enum FontMetrics {
    public static func metrics(
        family: String? = nil,
        size: Double,
        scale: CGFloat
    ) -> CellMetrics {
        precondition(size > 0 && scale > 0)
        let requestedFamily = family ?? "SF Mono"
        let font = resolveFont(requestedFamily: requestedFamily, pointSize: size * Double(scale))
        let glyph = glyphForAdvance(in: font)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = max(0, CTFontGetLeading(font))
        let cellWidth = ceil(max(advance.width, size * Double(scale) * 0.5))
        let cellHeight = ceil(ascent + descent + leading)
        let baseline = ceil(ascent + leading / 2)
        let underlineThickness = max(1, ceil(CTFontGetUnderlineThickness(font)))

        return CellMetrics(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            baseline: baseline,
            underlinePosition: CTFontGetUnderlinePosition(font),
            underlineThickness: underlineThickness,
            scale: scale,
            fontFamily: CTFontCopyFamilyName(font) as String,
            pointSize: size
        )
    }

    static func font(metrics: CellMetrics, bold: Bool, italic: Bool) -> CTFont {
        let size = metrics.pointSize * Double(metrics.scale)
        let base = resolveFont(requestedFamily: metrics.fontFamily, pointSize: size)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func resolveFont(requestedFamily: String, pointSize: Double) -> CTFont {
        for family in unique([requestedFamily, "SF Mono", "Menlo"]) {
            let font = CTFontCreateWithName(family as CFString, pointSize, nil)
            let actualFamily = CTFontCopyFamilyName(font) as String
            if actualFamily.caseInsensitiveCompare(family) == .orderedSame {
                return font
            }
        }
        return CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
    }

    private static func glyphForAdvance(in font: CTFont) -> CGGlyph {
        let characters: [UniChar] = [77]
        var glyph: CGGlyph = 0
        if CTFontGetGlyphsForCharacters(font, characters, &glyph, 1), glyph != 0 {
            return glyph
        }
        return CTFontGetGlyphWithName(font, "space" as CFString)
    }

    private static func unique(_ families: [String]) -> [String] {
        var seen = Set<String>()
        return families.filter { seen.insert($0.lowercased()).inserted }
    }
}
