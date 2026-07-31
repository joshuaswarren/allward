import AllwardCore
import AllwardDesign
import AllwardTerminal
import Foundation
import simd

public struct SceneRectangle: Hashable, Sendable {
    public let rect: SIMD4<Float>
    public let color: SIMD4<Float>

    public init(x: Float, y: Float, width: Float, height: Float, color: TokenColor) {
        rect = SIMD4(x, y, width, height)
        self.color = color.floatComponents
    }
}

public struct SceneGlyph: Hashable, Sendable {
    public let rect: SIMD4<Float>
    public let clipRect: SIMD4<Float>
    public let color: SIMD4<Float>
    public let request: GlyphRequest
}

public struct SceneRow: Hashable, Sendable {
    public var backgrounds: [SceneRectangle]
    public var monochromeGlyphs: [SceneGlyph]
    public var colorGlyphs: [SceneGlyph]
    public var decorations: [SceneRectangle]
    public var cursorAndFocus: [SceneRectangle]

    public init(
        backgrounds: [SceneRectangle] = [],
        monochromeGlyphs: [SceneGlyph] = [],
        colorGlyphs: [SceneGlyph] = [],
        decorations: [SceneRectangle] = [],
        cursorAndFocus: [SceneRectangle] = []
    ) {
        self.backgrounds = backgrounds
        self.monochromeGlyphs = monochromeGlyphs
        self.colorGlyphs = colorGlyphs
        self.decorations = decorations
        self.cursorAndFocus = cursorAndFocus
    }
}

public struct TerminalScene: Sendable {
    public let width: Float
    public let height: Float
    public let rows: [SceneRow]
    public let imagePlane: [ImagePlacement]

    public var glyphRequests: [GlyphRequest] {
        rows.flatMap { $0.monochromeGlyphs.map(\.request) + $0.colorGlyphs.map(\.request) }
    }
}

public struct SceneBuilder: Sendable {
    public let metrics: CellMetrics

    public init(metrics: CellMetrics) {
        self.metrics = metrics
    }

    public func build(
        snapshot: TerminalSnapshot,
        palette: DesignPalette,
        theme: TerminalTheme,
        focused: Bool
    ) -> TerminalScene {
        let width = Float(snapshot.geometry.columns) * Float(metrics.cellWidth)
        let height = Float(snapshot.geometry.rows) * Float(metrics.cellHeight)
        let selection = SelectionMap(snapshot: snapshot)
        let commandMarkers = commandMarkerRows(snapshot: snapshot, palette: palette)
        var rows: [SceneRow] = []
        rows.reserveCapacity(snapshot.geometry.rows)

        for rowIndex in 0 ..< snapshot.geometry.rows {
            let cells = normalizedRow(snapshot: snapshot, index: rowIndex)
            let selectedColumns = selection.columns(in: rowIndex, cells: cells)
            var row = buildRow(
                cells: cells,
                selectedColumns: selectedColumns,
                rowIndex: rowIndex,
                theme: theme
            )
            if let commandColor = commandMarkers[rowIndex] {
                row.backgrounds.append(
                    SceneRectangle(
                        x: 0,
                        y: Float(rowIndex + 1) * Float(metrics.cellHeight) - pixel,
                        width: Float(metrics.cellWidth),
                        height: pixel,
                        color: commandColor
                    )
                )
            }
            appendCursor(
                snapshot.cursor,
                to: &row,
                rowIndex: rowIndex,
                columns: snapshot.geometry.columns,
                theme: theme,
                focused: focused
            )
            rows.append(row)
        }

        return TerminalScene(width: width, height: height, rows: rows, imagePlane: snapshot.imagePlacements)
    }

    private var pixel: Float { 1 }

    private func buildRow(
        cells: [TerminalCell],
        selectedColumns: Set<Int>,
        rowIndex: Int,
        theme: TerminalTheme
    ) -> SceneRow {
        let y = Float(rowIndex) * Float(metrics.cellHeight)
        var row = SceneRow()
        appendBackgroundRuns(cells: cells, y: y, theme: theme, to: &row.backgrounds)
        appendSelectionRuns(selectedColumns: selectedColumns, y: y, theme: theme, to: &row.backgrounds)

        for column in cells.indices {
            let cell = cells[column]
            guard cell.span != .continuation else { continue }
            let selected = selectedColumns.contains(column)
            appendGlyph(
                cell: cell,
                rowIndex: rowIndex,
                column: column,
                selected: selected,
                y: y,
                theme: theme,
                to: &row
            )
            appendCellDecorations(
                cell: cell,
                column: column,
                y: y,
                theme: theme,
                to: &row.decorations
            )
        }
        return row
    }

    private func appendBackgroundRuns(
        cells: [TerminalCell],
        y: Float,
        theme: TerminalTheme,
        to output: inout [SceneRectangle]
    ) {
        guard !cells.isEmpty else { return }
        var runStart = 0
        var runColor = resolvedColors(cells[0].attributes, theme: theme).background
        for column in 1 ... cells.count {
            let nextColor = column < cells.count
                ? resolvedColors(cells[column].attributes, theme: theme).background
                : nil
            if nextColor != runColor {
                output.append(
                    SceneRectangle(
                        x: Float(runStart) * Float(metrics.cellWidth),
                        y: y,
                        width: Float(column - runStart) * Float(metrics.cellWidth),
                        height: Float(metrics.cellHeight),
                        color: runColor
                    )
                )
                if let nextColor {
                    runStart = column
                    runColor = nextColor
                }
            }
        }
    }

    private func appendSelectionRuns(
        selectedColumns: Set<Int>,
        y: Float,
        theme: TerminalTheme,
        to output: inout [SceneRectangle]
    ) {
        var start: Int?
        let maximum = selectedColumns.max() ?? -1
        guard maximum >= 0 else { return }
        for column in 0 ... maximum + 1 {
            if selectedColumns.contains(column) {
                if start == nil { start = column }
            } else if let runStart = start {
                output.append(
                    SceneRectangle(
                        x: Float(runStart) * Float(metrics.cellWidth),
                        y: y,
                        width: Float(column - runStart) * Float(metrics.cellWidth),
                        height: Float(metrics.cellHeight),
                        color: theme.selectionBackground
                    )
                )
                start = nil
            }
        }
    }

    private func appendGlyph(
        cell: TerminalCell,
        rowIndex: Int,
        column: Int,
        selected: Bool,
        y: Float,
        theme: TerminalTheme,
        to row: inout SceneRow
    ) {
        guard !cell.isBlank, !cell.attributes.flags.contains(.invisible) else { return }
        let span = cell.span == .wide ? 2 : 1
        let presentation = glyphPresentation(cell.text)
        let bold = cell.attributes.flags.contains(.bold)
        let italic = cell.attributes.flags.contains(.italic)
        let fontIdentity = FontMetrics.atlasIdentity(
            metrics: metrics,
            grapheme: cell.text,
            bold: bold,
            italic: italic
        )
        let colors = resolvedColors(cell.attributes, theme: theme)
        var foreground = selected ? theme.selectionForeground : colors.foreground
        if cell.attributes.flags.contains(.faint) {
            foreground = foreground.withAlpha(foreground.alpha * 0.62)
        }
        let rect = SIMD4<Float>(
            Float(column) * Float(metrics.cellWidth),
            y,
            Float(span) * Float(metrics.cellWidth),
            Float(metrics.cellHeight)
        )
        let key = GlyphAtlasKey(
            grapheme: cell.text,
            fontIdentity: fontIdentity,
            bold: bold,
            italic: italic,
            cellSpan: span,
            presentation: presentation,
            scale: metrics.scale
        )
        let glyph = SceneGlyph(
            rect: rect,
            clipRect: rect,
            color: foreground.floatComponents,
            request: GlyphRequest(key: key, row: rowIndex)
        )
        if presentation == .colorEmoji {
            row.colorGlyphs.append(glyph)
        } else {
            row.monochromeGlyphs.append(glyph)
        }
    }

    private func appendCellDecorations(
        cell: TerminalCell,
        column: Int,
        y: Float,
        theme: TerminalTheme,
        to output: inout [SceneRectangle]
    ) {
        let flags = cell.attributes.flags
        let span = cell.span == .wide ? 2 : 1
        let x = Float(column) * Float(metrics.cellWidth)
        let width = Float(span) * Float(metrics.cellWidth)
        let colors = resolvedColors(cell.attributes, theme: theme)
        let decorationColor = cell.attributes.underlineColor.map(theme.resolve) ?? colors.foreground
        let underlineY = y + Float(metrics.baseline - metrics.underlinePosition)
        let thickness = max(pixel, Float(metrics.underlineThickness))

        if flags.contains(.underline) || flags.contains(.curlyUnderline) || cell.attributes.hyperlinkID != nil {
            output.append(SceneRectangle(x: x, y: underlineY, width: width, height: thickness, color: decorationColor))
        }
        if flags.contains(.doubleUnderline) {
            output.append(
                SceneRectangle(
                    x: x,
                    y: underlineY - thickness * 2,
                    width: width,
                    height: thickness,
                    color: decorationColor
                )
            )
            output.append(
                SceneRectangle(
                    x: x,
                    y: underlineY + thickness,
                    width: width,
                    height: thickness,
                    color: decorationColor
                )
            )
        }
        if flags.contains(.strikethrough) {
            let strikeY = y + Float(metrics.baseline * 0.62)
            output.append(SceneRectangle(x: x, y: strikeY, width: width, height: thickness, color: colors.foreground))
        }
    }

    private func appendCursor(
        _ cursor: CursorState,
        to row: inout SceneRow,
        rowIndex: Int,
        columns: Int,
        theme: TerminalTheme,
        focused: Bool
    ) {
        guard cursor.visible, cursor.row == rowIndex else { return }
        let column = min(max(cursor.column, 0), columns - 1)
        let x = Float(column) * Float(metrics.cellWidth)
        let y = Float(rowIndex) * Float(metrics.cellHeight)
        // Every Mac terminal hollows the block cursor when the pane does not
        // hold the keyboard. It is the clearest answer to "where does my
        // typing go" and costs no chrome.
        if case .block = cursor.shape, !focused {
            appendOutline(
                to: &row, x: x, y: y,
                width: Float(metrics.cellWidth), height: Float(metrics.cellHeight),
                color: theme.cursor.withAlpha(0.72))
            return
        }
        switch cursor.shape {
        case .block:
            row.cursorAndFocus.append(
                SceneRectangle(
                    x: x,
                    y: y,
                    width: Float(metrics.cellWidth),
                    height: Float(metrics.cellHeight),
                    color: theme.cursor.withAlpha(0.68)
                )
            )
        case .underline:
            row.cursorAndFocus.append(
                SceneRectangle(
                    x: x,
                    y: y + Float(metrics.cellHeight) - max(pixel * 2, Float(metrics.underlineThickness)),
                    width: Float(metrics.cellWidth),
                    height: max(pixel * 2, Float(metrics.underlineThickness)),
                    color: theme.cursor
                )
            )
        case .bar:
            row.cursorAndFocus.append(
                SceneRectangle(
                    x: x,
                    y: y,
                    width: max(pixel * 2, Float(metrics.underlineThickness)),
                    height: Float(metrics.cellHeight),
                    color: theme.cursor
                )
            )
        }
    }

    /// A one-pixel rectangle outline, for the unfocused block cursor.
    private func appendOutline(
        to row: inout SceneRow, x: Float, y: Float, width: Float, height: Float,
        color: TokenColor
    ) {
        row.cursorAndFocus.append(
            SceneRectangle(x: x, y: y, width: width, height: pixel, color: color))
        row.cursorAndFocus.append(
            SceneRectangle(
                x: x, y: y + height - pixel, width: width, height: pixel, color: color))
        row.cursorAndFocus.append(
            SceneRectangle(x: x, y: y, width: pixel, height: height, color: color))
        row.cursorAndFocus.append(
            SceneRectangle(
                x: x + width - pixel, y: y, width: pixel, height: height, color: color))
    }

    private func normalizedRow(snapshot: TerminalSnapshot, index: Int) -> [TerminalCell] {
        var cells = snapshot.rows.indices.contains(index) ? snapshot.rows[index] : []
        if cells.count > snapshot.geometry.columns {
            cells.removeLast(cells.count - snapshot.geometry.columns)
        } else if cells.count < snapshot.geometry.columns {
            cells.append(contentsOf: repeatElement(.blank, count: snapshot.geometry.columns - cells.count))
        }
        return cells
    }

    private func resolvedColors(
        _ attributes: CellAttributes,
        theme: TerminalTheme
    ) -> (foreground: TokenColor, background: TokenColor) {
        let bold = attributes.flags.contains(.bold)
        let foreground = theme.resolveForeground(attributes.foreground, bold: bold)
        let background = theme.resolve(attributes.background)
        let (front, back) =
            attributes.flags.contains(.inverse)
            ? (foreground: background, background: foreground)
            : (foreground: foreground, background: background)
        // Contrast is enforced after inversion, on the pair that will be drawn.
        return (foreground: theme.meetingContrast(front, on: back), background: back)
    }

    private func glyphPresentation(_ text: String) -> GlyphPresentation {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0.value == 0xFE0E }) {
            return .monochrome
        }
        if scalars.contains(where: { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }) {
            return .colorEmoji
        }
        return .monochrome
    }

    private func commandMarkerRows(
        snapshot: TerminalSnapshot,
        palette: DesignPalette
    ) -> [Int: TokenColor] {
        let rowByID = visibleRowIndices(snapshot.rowIDs)
        var output: [Int: TokenColor] = [:]
        for region in snapshot.commandRegions {
            guard let row = rowByID[region.promptLine] else { continue }
            let color: TokenColor
            if region.isRunning {
                color = palette[.stateRunning]
            } else if region.succeeded == true {
                color = palette[.stateFinished]
            } else if region.succeeded == false {
                color = palette[.stateError]
            } else {
                continue
            }
            output[row] = color
        }
        return output
    }
}

private struct SelectionMap {
    private let ranges: [Int: Range<Int>]

    init(snapshot: TerminalSnapshot) {
        guard let selection = snapshot.selection else {
            ranges = [:]
            return
        }
        let rowByID = visibleRowIndices(snapshot.rowIDs)
        guard let firstRow = rowByID[selection.start.line], let secondRow = rowByID[selection.end.line] else {
            ranges = [:]
            return
        }
        var start = (row: firstRow, offset: selection.start.graphemeOffset)
        var end = (row: secondRow, offset: selection.end.graphemeOffset)
        if start.row > end.row || (start.row == end.row && start.offset > end.offset) {
            swap(&start, &end)
        }

        var result: [Int: Range<Int>] = [:]
        switch selection.mode {
        case .block:
            let lower = min(start.offset, end.offset)
            let upper = max(start.offset, end.offset)
            for row in start.row ... end.row where lower < upper {
                result[row] = lower ..< upper
            }
        case .stream:
            for row in start.row ... end.row {
                let lower = row == start.row ? start.offset : 0
                let upper = row == end.row ? end.offset : Int.max
                if lower < upper { result[row] = lower ..< upper }
            }
        }
        ranges = result
    }

    func columns(in row: Int, cells: [TerminalCell]) -> Set<Int> {
        guard let range = ranges[row] else { return [] }
        var selected: Set<Int> = []
        var graphemeIndex = 0
        for column in cells.indices {
            let cell = cells[column]
            guard cell.span != .continuation else { continue }
            if range.contains(graphemeIndex) {
                selected.insert(column)
                if cell.span == .wide, column + 1 < cells.count { selected.insert(column + 1) }
            }
            graphemeIndex += 1
        }
        return selected
    }
}

private func visibleRowIndices(_ rowIDs: [LineID]) -> [LineID: Int] {
    var indices: [LineID: Int] = [:]
    for (index, id) in rowIDs.enumerated() where indices[id] == nil {
        indices[id] = index
    }
    return indices
}

private extension TokenColor {
    var floatComponents: SIMD4<Float> {
        SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }
}
