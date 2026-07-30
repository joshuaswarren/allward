import CoreGraphics
import CoreText
import Foundation
import Metal

public enum GlyphPresentation: UInt8, Hashable, Sendable {
    case monochrome
    case colorEmoji
}

public struct GlyphAtlasKey: Hashable, Sendable {
    public let grapheme: String
    public let fontIdentity: String
    public let bold: Bool
    public let italic: Bool
    public let presentation: GlyphPresentation
    public let scale: CGFloat

    public init(
        grapheme: String,
        fontIdentity: String,
        bold: Bool,
        italic: Bool,
        presentation: GlyphPresentation,
        scale: CGFloat
    ) {
        self.grapheme = grapheme
        self.fontIdentity = fontIdentity
        self.bold = bold
        self.italic = italic
        self.presentation = presentation
        self.scale = scale
    }
}

public struct GlyphRequest: Hashable, Sendable {
    public let key: GlyphAtlasKey
    public let cellSpan: Int
    public let row: Int

    public init(key: GlyphAtlasKey, cellSpan: Int, row: Int) {
        self.key = key
        self.cellSpan = max(1, min(cellSpan, 2))
        self.row = row
    }
}

public struct GlyphAtlasEntry: Hashable, Sendable {
    public let u0: Float
    public let v0: Float
    public let u1: Float
    public let v1: Float
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum GlyphAtlasKind: Sendable {
    case monochrome
    case color

    var presentation: GlyphPresentation {
        self == .monochrome ? .monochrome : .colorEmoji
    }

    var pixelFormat: MTLPixelFormat {
        self == .monochrome ? .r8Unorm : .bgra8Unorm
    }

    var bytesPerPixel: Int {
        self == .monochrome ? 1 : 4
    }
}

private struct GlyphRaster: Sendable {
    let key: GlyphAtlasKey
    let cellSpan: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data
}

private actor GlyphRasterizationQueue {
    private let metrics: CellMetrics

    init(metrics: CellMetrics) {
        self.metrics = metrics
    }

    func rasterize(key: GlyphAtlasKey, cellSpan: Int) -> GlyphRaster {
        let width = max(1, Int(metrics.cellWidth.rounded()) * cellSpan)
        let height = max(1, Int(metrics.cellHeight.rounded()))
        let bytesPerPixel = key.presentation == .monochrome ? 1 : 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let resolvedGlyph = FontMetrics.resolvedGlyphFont(
            metrics: metrics,
            grapheme: key.grapheme,
            bold: key.bold,
            italic: key.italic
        )
        let font = resolvedGlyph.font
        let grapheme = resolvedGlyph.grapheme
        let isFallback = resolvedGlyph.isFallback

        bytes.withUnsafeMutableBytes { storage in
            guard let baseAddress = storage.baseAddress,
                  let context = makeContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bytesPerRow: bytesPerRow,
                      presentation: key.presentation
                  )
            else { return }

            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
            if key.presentation == .monochrome {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(
                    gray: 1,
                    alpha: 1
                )
            }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: grapheme, attributes: attributes)
            )
            var fontAscent: CGFloat = 0
            var fontDescent: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &fontAscent, &fontDescent, nil)
            if grapheme.unicodeScalars.contains(where: { (0x2500 ... 0xF8FF).contains($0.value) }) {
                print("FIT_DEBUG \(grapheme) fallback=\(isFallback) width=\(width) advance=\(lineWidth) font=\(key.fontIdentity)")
            }
            if isFallback, lineWidth > Double(width) + 0.5 {
                drawFitted(
                    line,
                    fontAscent: fontAscent,
                    fontDescent: fontDescent,
                    lineWidth: lineWidth,
                    width: width,
                    height: height,
                    in: context
                )
            } else {
                let x = key.presentation == .colorEmoji ? max(0, (Double(width) - lineWidth) / 2) : 0
                context.textPosition = CGPoint(x: x, y: CGFloat(height) - metrics.baseline)
                CTLineDraw(line, context)
            }
        }

        return GlyphRaster(
            key: key,
            cellSpan: cellSpan,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: Data(bytes)
        )
    }

    private func drawFitted(
        _ line: CTLine,
        fontAscent: CGFloat,
        fontDescent: CGFloat,
        lineWidth: Double,
        width: Int,
        height: Int,
        in context: CGContext
    ) {
        let baseline = CGFloat(height) - metrics.baseline
        let ascentScale = metrics.baseline / max(fontAscent, 1)
        let descentScale = fontDescent > 0 ? baseline / fontDescent : ascentScale

        context.saveGState()
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(
            x: CGFloat(Double(width) / lineWidth),
            y: min(ascentScale, descentScale)
        )
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func makeContext(
        data: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        presentation: GlyphPresentation
    ) -> CGContext? {
        if presentation == .monochrome {
            return CGContext(
                data: data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        return CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }

}

@MainActor
public final class GlyphAtlas {
    public private(set) var texture: MTLTexture
    public var rowsDidChange: (@MainActor ([Int]) -> Void)?

    private struct StoredEntry {
        var atlasEntry: GlyphAtlasEntry
        let raster: GlyphRaster
        var lastUsed: UInt64
        var dependentRows: Set<Int>
    }

    private struct Placement {
        let x: Int
        let y: Int
    }

    private struct Shelf {
        let y: Int
        let height: Int
        var nextX: Int
    }

    private struct ShelfPacker {
        let width: Int
        let height: Int
        var shelves: [Shelf] = []
        var nextY = 0

        mutating func place(width itemWidth: Int, height itemHeight: Int) -> Placement? {
            let paddedWidth = itemWidth + 1
            let paddedHeight = itemHeight + 1
            for index in shelves.indices where itemHeight <= shelves[index].height
                && shelves[index].nextX + paddedWidth <= width
            {
                let placement = Placement(x: shelves[index].nextX, y: shelves[index].y)
                shelves[index].nextX += paddedWidth
                return placement
            }
            guard nextY + paddedHeight <= height else { return nil }
            let placement = Placement(x: 0, y: nextY)
            shelves.append(Shelf(y: nextY, height: paddedHeight, nextX: paddedWidth))
            nextY += paddedHeight
            return placement
        }
    }

    private let device: MTLDevice
    private let kind: GlyphAtlasKind
    let capacityBytes: Int
    private let width: Int
    private let height: Int
    private let rasterizer: GlyphRasterizationQueue
    private var packer: ShelfPacker
    private var entries: [GlyphAtlasKey: StoredEntry] = [:]
    private var pendingRows: [GlyphAtlasKey: Set<Int>] = [:]
    private var rasterizing: Set<GlyphAtlasKey> = []
    private var clock: UInt64 = 0

    public init(
        device: MTLDevice,
        metrics: CellMetrics,
        kind: GlyphAtlasKind,
        budgetBytes: Int? = nil,
        maximumDimension: Int = 2_048
    ) {
        self.device = device
        self.kind = kind
        rasterizer = GlyphRasterizationQueue(metrics: metrics)
        let budget = max(64 * 64 * kind.bytesPerPixel, budgetBytes ?? Self.defaultBudget(for: kind))
        let dimensions = Self.dimensions(
            budget: budget,
            bytesPerPixel: kind.bytesPerPixel,
            maximum: maximumDimension
        )
        width = dimensions.width
        capacityBytes = dimensions.width * dimensions.height * kind.bytesPerPixel
        height = dimensions.height
        packer = ShelfPacker(width: dimensions.width, height: dimensions.height)
        texture = Self.makeTexture(device: device, kind: kind, width: dimensions.width, height: dimensions.height)
    }

    public func entry(for request: GlyphRequest) -> GlyphAtlasEntry? {
        precondition(request.key.presentation == kind.presentation)
        clock &+= 1
        if var stored = entries[request.key] {
            stored.lastUsed = clock
            stored.dependentRows.insert(request.row)
            entries[request.key] = stored
            return stored.atlasEntry
        }

        pendingRows[request.key, default: []].insert(request.row)
        if rasterizing.insert(request.key).inserted {
            scheduleRasterization(key: request.key, cellSpan: request.cellSpan)
        }
        return nil
    }

    public func prepare(_ requests: [GlyphRequest]) async {
        var unique: [GlyphAtlasKey: GlyphRequest] = [:]
        for request in requests where request.key.presentation == kind.presentation {
            unique[request.key] = request
        }
        for request in unique.values where entries[request.key] == nil {
            let raster = await rasterizer.rasterize(key: request.key, cellSpan: request.cellSpan)
            pendingRows[request.key, default: []].insert(request.row)
            insert(raster)
        }
    }

    private func scheduleRasterization(key: GlyphAtlasKey, cellSpan: Int) {
        Task { [weak self] in
            guard let self else { return }
            let raster = await rasterizer.rasterize(key: key, cellSpan: cellSpan)
            insert(raster)
        }
    }

    private func insert(_ raster: GlyphRaster) {
        rasterizing.remove(raster.key)
        if var stored = entries[raster.key] {
            let rows = pendingRows.removeValue(forKey: raster.key) ?? []
            stored.dependentRows.formUnion(rows)
            entries[raster.key] = stored
            notify(rows)
            return
        }
        clock &+= 1
        let rows = pendingRows.removeValue(forKey: raster.key) ?? []
        if let placement = packer.place(width: raster.width, height: raster.height) {
            let atlasEntry = makeEntry(raster: raster, placement: placement)
            upload(raster, placement: placement, texture: texture)
            entries[raster.key] = StoredEntry(
                atlasEntry: atlasEntry,
                raster: raster,
                lastUsed: clock,
                dependentRows: rows
            )
            notify(rows)
            return
        }
        rebuild(inserting: raster, rows: rows)
    }

    private func rebuild(inserting raster: GlyphRaster, rows: Set<Int>) {
        var candidates = entries
        candidates[raster.key] = StoredEntry(
            atlasEntry: GlyphAtlasEntry(
                u0: 0,
                v0: 0,
                u1: 0,
                v1: 0,
                pixelWidth: raster.width,
                pixelHeight: raster.height
            ),
            raster: raster,
            lastUsed: clock,
            dependentRows: rows
        )
        var invalidatedRows = Set(candidates.values.flatMap(\.dependentRows))
        var packed: [GlyphAtlasKey: Placement]?

        while packed == nil && !candidates.isEmpty {
            packed = pack(candidates)
            if packed == nil, let oldest = candidates.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                invalidatedRows.formUnion(oldest.value.dependentRows)
                candidates.removeValue(forKey: oldest.key)
            }
        }

        guard let placements = packed else {
            notify(invalidatedRows)
            return
        }
        let replacement = Self.makeTexture(device: device, kind: kind, width: width, height: height)
        var replacementEntries: [GlyphAtlasKey: StoredEntry] = [:]
        for (key, var stored) in candidates {
            guard let placement = placements[key] else { continue }
            upload(stored.raster, placement: placement, texture: replacement)
            stored.atlasEntry = makeEntry(raster: stored.raster, placement: placement)
            replacementEntries[key] = stored
        }
        texture = replacement
        entries = replacementEntries
        packer = packerFor(candidates)
        notify(invalidatedRows)
    }

    private func pack(_ candidates: [GlyphAtlasKey: StoredEntry]) -> [GlyphAtlasKey: Placement]? {
        var candidatePacker = ShelfPacker(width: width, height: height)
        var placements: [GlyphAtlasKey: Placement] = [:]
        let ordered = candidates.sorted {
            if $0.value.raster.height == $1.value.raster.height {
                return $0.value.raster.width > $1.value.raster.width
            }
            return $0.value.raster.height > $1.value.raster.height
        }
        for (key, stored) in ordered {
            guard let placement = candidatePacker.place(
                width: stored.raster.width,
                height: stored.raster.height
            ) else { return nil }
            placements[key] = placement
        }
        return placements
    }

    private func packerFor(_ candidates: [GlyphAtlasKey: StoredEntry]) -> ShelfPacker {
        var rebuilt = ShelfPacker(width: width, height: height)
        let ordered = candidates.sorted {
            if $0.value.raster.height == $1.value.raster.height {
                return $0.value.raster.width > $1.value.raster.width
            }
            return $0.value.raster.height > $1.value.raster.height
        }
        for (_, stored) in ordered {
            _ = rebuilt.place(width: stored.raster.width, height: stored.raster.height)
        }
        return rebuilt
    }

    private func makeEntry(raster: GlyphRaster, placement: Placement) -> GlyphAtlasEntry {
        GlyphAtlasEntry(
            u0: (Float(placement.x) + 0.5) / Float(width),
            v0: (Float(placement.y) + 0.5) / Float(height),
            u1: (Float(placement.x + raster.width) - 0.5) / Float(width),
            v1: (Float(placement.y + raster.height) - 0.5) / Float(height),
            pixelWidth: raster.width,
            pixelHeight: raster.height
        )
    }

    private func upload(_ raster: GlyphRaster, placement: Placement, texture: MTLTexture) {
        raster.bytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(placement.x, placement.y, raster.width, raster.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: raster.bytesPerRow
            )
        }
    }

    private func notify(_ rows: Set<Int>) {
        guard !rows.isEmpty else { return }
        rowsDidChange?(rows.sorted())
    }

    private static func defaultBudget(for kind: GlyphAtlasKind) -> Int {
        kind == .monochrome ? 4 * 1_024 * 1_024 : 16 * 1_024 * 1_024
    }

    private static func dimensions(budget: Int, bytesPerPixel: Int, maximum: Int) -> (width: Int, height: Int) {
        let pixelBudget = max(4_096, budget / bytesPerPixel)
        var width = 64
        let desired = Int(Double(pixelBudget).squareRoot())
        while width * 2 <= desired && width * 2 <= maximum { width *= 2 }
        let height = max(64, min(maximum, pixelBudget / width))
        return (width, height)
    }

    static func workingSetBudget(
        requests: [GlyphRequest],
        metrics: CellMetrics,
        kind: GlyphAtlasKind
    ) -> Int {
        var spans: [GlyphAtlasKey: Int] = [:]
        for request in requests where request.key.presentation == kind.presentation {
            spans[request.key] = max(spans[request.key] ?? 0, request.cellSpan)
        }
        let cellWidth = max(1, Int(metrics.cellWidth.rounded()))
        let cellHeight = max(1, Int(metrics.cellHeight.rounded()))
        let workingSetBytes = spans.values.reduce(0) { total, span in
            total + cellWidth * span * cellHeight * kind.bytesPerPixel
        }
        return max(defaultBudget(for: kind), workingSetBytes * 2)
    }

    private static func makeTexture(
        device: MTLDevice,
        kind: GlyphAtlasKind,
        width: Int,
        height: Int
    ) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: kind.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("Metal could not allocate a glyph atlas")
        }
        texture.label = kind == .monochrome ? "Monochrome glyph atlas" : "Colour glyph atlas"
        return texture
    }
}
