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

struct ResolvedGlyphFont {
    let font: CTFont
    let grapheme: String
    let atlasIdentity: String
}

public enum FontMetrics {
    // CoreText font descriptors are immutable despite lacking Sendable conformance.
    nonisolated(unsafe) private static let installedFontDescriptors: [CTFontDescriptor] = {
        let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        return names
            .filter { $0.caseInsensitiveCompare("LastResort") != .orderedSame }
            .map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) }
    }()

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

    static func baseFont(metrics: CellMetrics) -> CTFont {
        resolveFont(
            requestedFamily: metrics.fontFamily,
            pointSize: metrics.pointSize * Double(metrics.scale)
        )
    }

    static func resolvedGlyphFont(
        metrics: CellMetrics,
        grapheme: String,
        bold: Bool,
        italic: Bool
    ) -> ResolvedGlyphFont {
        let baseFont = baseFont(metrics: metrics)
        let cascadedFont = cascadingFont(baseFont: baseFont, grapheme: grapheme)
        let hasCoverage = font(cascadedFont, covers: grapheme)
        let drawableGrapheme = hasCoverage ? grapheme : "\u{FFFD}"
        let resolvedFont = hasCoverage
            ? cascadedFont
            : cascadingFont(baseFont: baseFont, grapheme: drawableGrapheme)
        let styledFont = applyingTraits(
            bold: bold,
            italic: italic,
            to: resolvedFont,
            covering: drawableGrapheme
        )
        return ResolvedGlyphFont(
            font: styledFont,
            grapheme: drawableGrapheme,
            atlasIdentity: "\(identity(of: baseFont))>\(identity(of: styledFont))"
        )
    }

    static func atlasIdentity(
        metrics: CellMetrics,
        grapheme: String,
        bold: Bool,
        italic: Bool
    ) -> String {
        resolvedGlyphFont(
            metrics: metrics,
            grapheme: grapheme,
            bold: bold,
            italic: italic
        ).atlasIdentity
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

    private static func cascadingFont(baseFont: CTFont, grapheme: String) -> CTFont {
        let range = CFRange(location: 0, length: grapheme.utf16.count)
        let systemFont = CTFontCreateForString(baseFont, grapheme as CFString, range)
        guard isLastResort(systemFont) else { return systemFont }

        let attributes = [
            kCTFontCascadeListAttribute as String: installedFontDescriptors,
        ] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        let expandedBaseFont = CTFontCreateCopyWithAttributes(
            baseFont,
            CTFontGetSize(baseFont),
            nil,
            descriptor
        )
        return CTFontCreateForString(expandedBaseFont, grapheme as CFString, range)
    }

    private static func isLastResort(_ font: CTFont) -> Bool {
        let postScriptName = CTFontCopyPostScriptName(font) as String
        return postScriptName.caseInsensitiveCompare("LastResort") == .orderedSame
    }

    private static func applyingTraits(
        bold: Bool,
        italic: Bool,
        to font: CTFont,
        covering grapheme: String
    ) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        guard !traits.isEmpty,
              let styledFont = CTFontCreateCopyWithSymbolicTraits(
                  font,
                  CTFontGetSize(font),
                  nil,
                  traits,
                  traits
              ),
              self.font(styledFont, covers: grapheme)
        else {
            return font
        }
        return styledFont
    }

    private static func font(_ font: CTFont, covers grapheme: String) -> Bool {
        guard !isLastResort(font) else { return false }
        let characters = Array(grapheme.utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return characters.withUnsafeBufferPointer { characterBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                CTFontGetGlyphsForCharacters(
                    font,
                    characterBuffer.baseAddress!,
                    glyphBuffer.baseAddress!,
                    characters.count
                )
            }
        }
    }

    private static func identity(of font: CTFont) -> String {
        let postScriptName = CTFontCopyPostScriptName(font) as String
        let traits = CTFontGetSymbolicTraits(font).rawValue
        return "\(postScriptName)@\(CTFontGetSize(font))#\(traits)"
    }

    private static func unique(_ families: [String]) -> [String] {
        var seen = Set<String>()
        return families.filter { seen.insert($0.lowercased()).inserted }
    }
}
