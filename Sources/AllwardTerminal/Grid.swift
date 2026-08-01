import AllwardCore

struct PackedTerminalCell: Hashable, Sendable {
    var grapheme: UInt32
    var attributes: UInt32
    var span: TerminalCell.Span
    var isProtected: Bool

    static let blank = PackedTerminalCell(grapheme: 0, attributes: 0, span: .narrow, isProtected: false)
}

struct GridLine: Sendable {
    var id: LineID
    var cells: [PackedTerminalCell]
    var hardBreak: Bool
}

private struct SavedCursor: Sendable {
    var cursor: CursorState
    var attributes: CellAttributes
    var originMode: Bool
}

private struct ScreenStorage: Sendable {
    var cells: [PackedTerminalCell]
    var rowIDs: [LineID]
    var softWrapped: [Bool]
    var cursor = CursorState()
    var savedCursor: SavedCursor?
    var attributes = CellAttributes.default
    var scrollTop = 0
    var scrollBottom: Int

    init(geometry: TerminalGeometry, firstLineID: UInt64) {
        cells = Array(repeating: .blank, count: geometry.rows * geometry.columns)
        rowIDs = (0..<geometry.rows).map { LineID(rawValue: firstLineID + UInt64($0)) }
        softWrapped = Array(repeating: false, count: geometry.rows)
        scrollBottom = geometry.rows - 1
    }
}

struct Grid: Sendable {
    private(set) var geometry: TerminalGeometry
    private var primary: ScreenStorage
    private var alternate: ScreenStorage
    private(set) var alternateActive = false
    private var nextLineRaw: UInt64

    init(geometry: TerminalGeometry) {
        self.geometry = geometry
        primary = ScreenStorage(geometry: geometry, firstLineID: 1)
        alternate = ScreenStorage(geometry: geometry, firstLineID: UInt64(geometry.rows + 1))
        nextLineRaw = UInt64(geometry.rows * 2 + 1)
    }

    var cursor: CursorState { alternateActive ? alternate.cursor : primary.cursor }
    var currentAttributes: CellAttributes { alternateActive ? alternate.attributes : primary.attributes }
    var rowIDs: [LineID] { alternateActive ? alternate.rowIDs : primary.rowIDs }
    var scrollTop: Int { alternateActive ? alternate.scrollTop : primary.scrollTop }
    var scrollBottom: Int { alternateActive ? alternate.scrollBottom : primary.scrollBottom }

    mutating func setCurrentAttributes(_ value: CellAttributes) {
        if alternateActive { alternate.attributes = value } else { primary.attributes = value }
    }
    func previousClusterText(graphemes: GraphemeTable) -> String {
        let screen = active
        var column = screen.cursor.wrapPending ? geometry.columns - 1 : screen.cursor.column - 1
        var row = screen.cursor.row
        if column < 0, row > 0 { row -= 1; column = geometry.columns - 1 }
        guard row >= 0, column >= 0 else { return "" }
        var index = offset(row: row, column: column)
        if screen.cells[index].span == .continuation, column > 0 { index -= 1 }
        return screen.cells[index].span == .continuation ? "" : graphemes[screen.cells[index].grapheme]
    }


    mutating func attachToPrevious(
        _ scalar: Unicode.Scalar,
        width: Int,
        autoWrap: Bool,
        graphemes: inout GraphemeTable
    ) -> Int? {
        var screen = active
        var column = screen.cursor.column - 1
        var row = screen.cursor.row
        if screen.cursor.wrapPending { column = geometry.columns - 1 }
        if column < 0, row > 0 { row -= 1; column = geometry.columns - 1 }
        guard row >= 0, column >= 0 else { return nil }
        var index = offset(row: row, column: column)
        if screen.cells[index].span == .continuation, column > 0 { index -= 1 }
        guard screen.cells[index].span != .continuation else { return nil }
        let existing = graphemes[screen.cells[index].grapheme]
        screen.cells[index].grapheme = graphemes.intern(existing + String(scalar))
        let leadColumn = index % geometry.columns
        let oldWidth = screen.cells[index].span == .wide ? 2 : 1
        let newWidth = min(max(width, 1), geometry.columns == 1 ? 1 : 2)
        if oldWidth == 1, newWidth == 2, leadColumn + 1 < geometry.columns {
            screen.cells[index].span = .wide
            screen.cells[index + 1] = PackedTerminalCell(
                grapheme: 0,
                attributes: screen.cells[index].attributes,
                span: .continuation,
                isProtected: screen.cells[index].isProtected
            )
            if screen.cursor.row == row {
                screen.cursor.column = min(geometry.columns - 1, leadColumn + 1)
                screen.cursor.wrapPending = autoWrap && leadColumn + 2 >= geometry.columns
                if !screen.cursor.wrapPending { screen.cursor.column += 1 }
            }
        } else if oldWidth == 2, newWidth == 1 {
            screen.cells[index].span = .narrow
            screen.cells[index + 1] = .blank
            if screen.cursor.row == row {
                screen.cursor.column = min(geometry.columns - 1, leadColumn + 1)
                screen.cursor.wrapPending = false
            }
        }
        active = screen
        return row
    }

    mutating func print(
        width: Int,
        attributes: UInt32,
        protected: Bool,
        autoWrap: Bool,
        insertMode: Bool
    ) -> [GridLine] {
        var screen = active
        var scrolled: [GridLine] = []
        if screen.cursor.wrapPending {
            if autoWrap { scrolled = wrap(&screen) }
            else { screen.cursor.wrapPending = false }
        }
        let cellWidth = geometry.columns == 1 ? 1 : min(max(width, 1), 2)
        if cellWidth == 2 && screen.cursor.column == geometry.columns - 1 {
            if autoWrap { scrolled += wrap(&screen) }
            else { active = screen; return scrolled }
        }
        if insertMode { shiftRight(&screen, row: screen.cursor.row, column: screen.cursor.column, count: cellWidth) }
        clearWideCell(at: screen.cursor.row, column: screen.cursor.column, screen: &screen)
        let lead = offset(row: screen.cursor.row, column: screen.cursor.column)
        screen.cells[lead] = PackedTerminalCell(
            grapheme: UInt32.max,
            attributes: attributes,
            span: cellWidth == 2 ? .wide : .narrow,
            isProtected: protected
        )
        if cellWidth == 2 {
            screen.cells[lead + 1] = PackedTerminalCell(
                grapheme: 0, attributes: attributes, span: .continuation, isProtected: protected
            )
        }
        if screen.cursor.column + cellWidth >= geometry.columns {
            screen.cursor.column = geometry.columns - 1
            screen.cursor.wrapPending = autoWrap
        } else {
            screen.cursor.column += cellWidth
            screen.cursor.wrapPending = false
        }
        active = screen
        return scrolled
    }

    mutating func replaceSentinelGrapheme(with reference: UInt32) {
        var screen = active
        for index in screen.cells.indices.reversed() where screen.cells[index].grapheme == UInt32.max {
            screen.cells[index].grapheme = reference
            active = screen
            return
        }
    }

    mutating func carriageReturn() {
        updateCursor { $0.column = 0; $0.wrapPending = false }
    }

    mutating func backspace() {
        updateCursor { $0.column = max(0, $0.column - 1); $0.wrapPending = false }
    }

    mutating func lineFeed() -> [GridLine] {
        var screen = active
        screen.cursor.wrapPending = false
        let lines: [GridLine]
        if screen.cursor.row == screen.scrollBottom { lines = scrollUp(&screen, count: 1) }
        else { screen.cursor.row = min(geometry.rows - 1, screen.cursor.row + 1); lines = [] }
        active = screen
        return lines
    }

    mutating func nextLine() -> [GridLine] {
        carriageReturn()
        return lineFeed()
    }

    mutating func reverseIndex() {
        var screen = active
        screen.cursor.wrapPending = false
        if screen.cursor.row == screen.scrollTop { scrollDown(&screen, count: 1) }
        else { screen.cursor.row = max(0, screen.cursor.row - 1) }
        active = screen
    }

    mutating func moveVertical(_ delta: Int, originMode: Bool) {
        var screen = active
        let lower = originMode ? screen.scrollTop : 0
        let upper = originMode ? screen.scrollBottom : geometry.rows - 1
        screen.cursor.row = min(upper, max(lower, screen.cursor.row + delta))
        screen.cursor.wrapPending = false
        active = screen
    }

    mutating func moveHorizontal(_ delta: Int) {
        let maximumColumn = geometry.columns - 1
        updateCursor {
            $0.column = min(maximumColumn, max(0, $0.column + delta))
            $0.wrapPending = false
        }
    }

    mutating func position(row: Int, column: Int, originMode: Bool) {
        var screen = active
        let base = originMode ? screen.scrollTop : 0
        let lower = originMode ? screen.scrollTop : 0
        let upper = originMode ? screen.scrollBottom : geometry.rows - 1
        screen.cursor.row = min(upper, max(lower, base + max(0, row - 1)))
        screen.cursor.column = min(geometry.columns - 1, max(0, column - 1))
        screen.cursor.wrapPending = false
        active = screen
    }

    mutating func horizontalAbsolute(_ column: Int) { positionColumn(column - 1) }
    mutating func verticalAbsolute(_ row: Int, originMode: Bool) {
        position(row: row, column: cursor.column + 1, originMode: originMode)
    }

    mutating func eraseLine(_ mode: EraseMode, selective: Bool, attributes: UInt32) {
        var screen = active
        let row = screen.cursor.row
        let range: ClosedRange<Int>
        switch mode {
        case .after, .scrollback: range = screen.cursor.column...(geometry.columns - 1)
        case .before: range = 0...screen.cursor.column
        case .all: range = 0...(geometry.columns - 1)
        }
        erase(&screen, row: row, columns: range, selective: selective, attributes: attributes)
        active = screen
    }

    mutating func eraseDisplay(_ mode: EraseMode, selective: Bool, attributes: UInt32) {
        var screen = active
        switch mode {
        case .after:
            erase(
                &screen,
                row: screen.cursor.row,
                columns: screen.cursor.column...(geometry.columns - 1),
                selective: selective,
                attributes: attributes
            )
            if screen.cursor.row < geometry.rows - 1 {
                for row in (screen.cursor.row + 1)..<geometry.rows {
                    erase(
                        &screen,
                        row: row,
                        columns: 0...(geometry.columns - 1),
                        selective: selective,
                        attributes: attributes
                    )
                }
            }
        case .before:
            if screen.cursor.row > 0 {
                for row in 0..<screen.cursor.row {
                    erase(
                        &screen,
                        row: row,
                        columns: 0...(geometry.columns - 1),
                        selective: selective,
                        attributes: attributes
                    )
                }
            }
            erase(
                &screen,
                row: screen.cursor.row,
                columns: 0...screen.cursor.column,
                selective: selective,
                attributes: attributes
            )
        case .all:
            for row in 0..<geometry.rows {
                erase(
                    &screen,
                    row: row,
                    columns: 0...(geometry.columns - 1),
                    selective: selective,
                    attributes: attributes
                )
            }
        case .scrollback: break
        }
        active = screen
    }

    mutating func eraseCharacters(_ count: Int, selective: Bool, attributes: UInt32) {
        var screen = active
        let end = min(geometry.columns - 1, screen.cursor.column + max(1, count) - 1)
        erase(
            &screen,
            row: screen.cursor.row,
            columns: screen.cursor.column...end,
            selective: selective,
            attributes: attributes
        )
        active = screen
    }

    mutating func insertCharacters(_ count: Int) {
        var screen = active
        shiftRight(&screen, row: screen.cursor.row, column: screen.cursor.column, count: max(1, count))
        active = screen
    }

    mutating func deleteCharacters(_ count: Int) {
        var screen = active
        let rowStart = offset(row: screen.cursor.row, column: 0)
        let start = rowStart + screen.cursor.column
        let amount = min(max(1, count), geometry.columns - screen.cursor.column)
        for column in screen.cursor.column..<(geometry.columns - amount) {
            screen.cells[rowStart + column] = screen.cells[rowStart + column + amount]
        }
        for index in (rowStart + geometry.columns - amount)..<(rowStart + geometry.columns) {
            screen.cells[index] = .blank
        }
        if start < screen.cells.count { normalizeWideCells(&screen, row: screen.cursor.row) }
        active = screen
    }

    mutating func insertLines(_ count: Int) {
        var screen = active
        guard (screen.scrollTop...screen.scrollBottom).contains(screen.cursor.row) else { return }
        scrollDown(&screen, from: screen.cursor.row, to: screen.scrollBottom, count: count)
        active = screen
    }

    mutating func deleteLines(_ count: Int) {
        var screen = active
        guard (screen.scrollTop...screen.scrollBottom).contains(screen.cursor.row) else { return }
        _ = scrollUp(&screen, from: screen.cursor.row, to: screen.scrollBottom, count: count)
        active = screen
    }

    mutating func scrollUp(_ count: Int) -> [GridLine] {
        var screen = active
        let result = scrollUp(&screen, count: count)
        active = screen
        return result
    }

    mutating func scrollDown(_ count: Int) {
        var screen = active
        scrollDown(&screen, count: count)
        active = screen
    }

    mutating func setMargins(top: Int, bottom: Int) {
        var screen = active
        let resolvedBottom = bottom == 0 ? geometry.rows : bottom
        guard top >= 1, resolvedBottom <= geometry.rows, top < resolvedBottom else { return }
        screen.scrollTop = top - 1
        screen.scrollBottom = resolvedBottom - 1
        screen.cursor = CursorState(row: 0, column: 0, visible: screen.cursor.visible, shape: screen.cursor.shape)
        active = screen
    }

    mutating func saveCursor(originMode: Bool) {
        var screen = active
        screen.savedCursor = SavedCursor(cursor: screen.cursor, attributes: screen.attributes, originMode: originMode)
        active = screen
    }

    mutating func restoreCursor() -> Bool? {
        var screen = active
        guard let saved = screen.savedCursor else { return nil }
        screen.cursor = saved.cursor
        screen.attributes = saved.attributes
        active = screen
        return saved.originMode
    }

    mutating func setCursorVisible(_ visible: Bool) { updateCursor { $0.visible = visible } }

    mutating func setAlternate(_ enabled: Bool, clear: Bool, savePrimary: Bool, originMode: Bool) -> Bool? {
        if enabled {
            if savePrimary {
                primary.savedCursor = SavedCursor(
                    cursor: primary.cursor,
                    attributes: primary.attributes,
                    originMode: originMode
                )
            }
            alternateActive = true
            if clear { clearActive() }
            return nil
        }
        alternateActive = false
        if savePrimary, let saved = primary.savedCursor {
            primary.cursor = saved.cursor
            primary.attributes = saved.attributes
            return saved.originMode
        }
        return nil
    }

    mutating func clearActive() {
        var screen = active
        screen.cells = Array(repeating: .blank, count: geometry.rows * geometry.columns)
        screen.rowIDs = (0..<geometry.rows).map { _ in allocateLineID() }
        screen.softWrapped = Array(repeating: false, count: geometry.rows)
        screen.cursor = CursorState()
        screen.scrollTop = 0
        screen.scrollBottom = geometry.rows - 1
        active = screen
    }

    mutating func alignmentTest(grapheme: UInt32, attributes: UInt32) {
        var screen = active
        let cell = PackedTerminalCell(
            grapheme: grapheme, attributes: attributes, span: .narrow, isProtected: false
        )
        screen.cells = Array(repeating: cell, count: geometry.rows * geometry.columns)
        active = screen
    }


    func packedRows() -> [GridLine] {
        let screen = active
        return (0..<geometry.rows).map { row in
            let start = offset(row: row, column: 0)
            return GridLine(
                id: screen.rowIDs[row],
                cells: Array(screen.cells[start..<(start + geometry.columns)]),
                hardBreak: !screen.softWrapped[row]
            )
        }
    }
    func primaryRows() -> [GridLine] {
        packedRows(from: primary, columns: geometry.columns)
    }


    mutating func replaceForResize(
        rows: [GridLine],
        inactiveRows resizedInactiveRows: [GridLine]? = nil,
        geometry newGeometry: TerminalGeometry,
        cursorAnchor: SelectionAnchor?
    ) {
        let oldColumns = geometry.columns
        let oldActive = active
        let oldInactive = alternateActive ? primary : alternate
        let inactiveRows = resizedInactiveRows ?? packedRows(from: oldInactive, columns: oldColumns)
        geometry = newGeometry
        let resizedActive = makeStorage(
            rows: rows,
            geometry: newGeometry,
            prior: oldActive,
            cursorAnchor: cursorAnchor
        )
        let resizedInactive = makeStorage(
            rows: inactiveRows,
            geometry: newGeometry,
            prior: oldInactive,
            cursorAnchor: nil
        )
        if alternateActive {
            alternate = resizedActive
            primary = resizedInactive
        } else {
            primary = resizedActive
            alternate = resizedInactive
        }
    }

    private mutating func makeStorage(
        rows: [GridLine],
        geometry: TerminalGeometry,
        prior: ScreenStorage,
        cursorAnchor: SelectionAnchor?
    ) -> ScreenStorage {
        var storage = ScreenStorage(geometry: geometry, firstLineID: nextLineRaw)
        nextLineRaw += UInt64(geometry.rows)
        let visible = Array(rows.suffix(geometry.rows))
        // Content sits at the top and the spare space goes below it. Pushing
        // short content to the bottom instead makes a grown window drop its
        // prompt to the last row, which is not where the shell left it.
        let rowOffset = 0
        for (sourceIndex, line) in visible.enumerated() {
            let targetRow = rowOffset + sourceIndex
            storage.rowIDs[targetRow] = line.id
            storage.softWrapped[targetRow] = !line.hardBreak
            for column in 0..<min(geometry.columns, line.cells.count) {
                storage.cells[targetRow * geometry.columns + column] = line.cells[column]
            }
        }
        storage.attributes = prior.attributes
        storage.savedCursor = prior.savedCursor
        storage.cursor = prior.cursor
        storage.cursor.row = min(geometry.rows - 1, max(0, storage.cursor.row + rowOffset))
        storage.cursor.column = min(geometry.columns - 1, max(0, storage.cursor.column))
        storage.cursor.wrapPending = false
        storage.scrollTop = min(prior.scrollTop, geometry.rows - 1)
        storage.scrollBottom = min(max(storage.scrollTop, prior.scrollBottom), geometry.rows - 1)
        if let anchor = cursorAnchor {
            var remaining = max(0, anchor.graphemeOffset)
            let matchingRows = storage.rowIDs.indices.filter { storage.rowIDs[$0] == anchor.line }
            for (position, row) in matchingRows.enumerated() {
                let start = row * geometry.columns
                let rowCells = storage.cells[start..<(start + geometry.columns)]
                let graphemeColumns = rowCells.indices.filter {
                    rowCells[$0].span != .continuation
                }.map { $0 - start }
                let isLast = position == matchingRows.count - 1
                if remaining < graphemeColumns.count {
                    storage.cursor.row = row
                    storage.cursor.column = graphemeColumns[remaining]
                    break
                }
                if isLast {
                    storage.cursor.row = row
                    storage.cursor.column = max(0, min(geometry.columns - 1, rowCells.count - 1))
                    storage.cursor.wrapPending = remaining >= graphemeColumns.count
                    break
                }
                remaining -= graphemeColumns.count
            }
        }
        return storage
    }

    private func packedRows(from screen: ScreenStorage, columns: Int) -> [GridLine] {
        (0..<screen.rowIDs.count).map { row in
            let start = row * columns
            return GridLine(
                id: screen.rowIDs[row],
                cells: Array(screen.cells[start..<(start + columns)]),
                hardBreak: !screen.softWrapped[row]
            )
        }
    }

    private var active: ScreenStorage {
        get { alternateActive ? alternate : primary }
        set { if alternateActive { alternate = newValue } else { primary = newValue } }
    }

    private func offset(row: Int, column: Int) -> Int { row * geometry.columns + column }

    private mutating func positionColumn(_ column: Int) {
        let maximumColumn = geometry.columns - 1
        updateCursor { $0.column = min(maximumColumn, max(0, column)); $0.wrapPending = false }
    }

    private mutating func updateCursor(_ body: (inout CursorState) -> Void) {
        if alternateActive { body(&alternate.cursor) } else { body(&primary.cursor) }
    }

    private mutating func wrap(_ screen: inout ScreenStorage) -> [GridLine] {
        let lineID = screen.rowIDs[screen.cursor.row]
        screen.softWrapped[screen.cursor.row] = true
        screen.cursor.column = 0
        screen.cursor.wrapPending = false
        if screen.cursor.row == screen.scrollBottom {
            let removed = scrollUp(&screen, count: 1)
            screen.rowIDs[screen.scrollBottom] = lineID
            return removed
        }
        screen.cursor.row = min(geometry.rows - 1, screen.cursor.row + 1)
        screen.rowIDs[screen.cursor.row] = lineID
        return []
    }

    private mutating func scrollUp(_ screen: inout ScreenStorage, count: Int) -> [GridLine] {
        scrollUp(&screen, from: screen.scrollTop, to: screen.scrollBottom, count: count)
    }

    private mutating func scrollUp(
        _ screen: inout ScreenStorage,
        from top: Int,
        to bottom: Int,
        count: Int
    ) -> [GridLine] {
        let amount = min(max(1, count), bottom - top + 1)
        var removed: [GridLine] = []
        removed.reserveCapacity(amount)
        for row in top..<(top + amount) {
            let start = offset(row: row, column: 0)
            removed.append(GridLine(
                id: screen.rowIDs[row],
                cells: Array(screen.cells[start..<(start + geometry.columns)]),
                hardBreak: !screen.softWrapped[row]
            ))
        }
        if top + amount <= bottom {
            for row in top...(bottom - amount) { copyRow(&screen, from: row + amount, to: row) }
        }
        for row in (bottom - amount + 1)...bottom { blankRow(&screen, row: row) }
        return removed
    }

    private mutating func scrollDown(_ screen: inout ScreenStorage, count: Int) {
        scrollDown(&screen, from: screen.scrollTop, to: screen.scrollBottom, count: count)
    }

    private mutating func scrollDown(_ screen: inout ScreenStorage, from top: Int, to bottom: Int, count: Int) {
        let amount = min(max(1, count), bottom - top + 1)
        if top <= bottom - amount {
            for row in stride(from: bottom, through: top + amount, by: -1) {
                copyRow(&screen, from: row - amount, to: row)
            }
        }
        for row in top..<(top + amount) { blankRow(&screen, row: row) }
    }

    private mutating func copyRow(_ screen: inout ScreenStorage, from source: Int, to target: Int) {
        for column in 0..<geometry.columns {
            screen.cells[offset(row: target, column: column)] = screen.cells[offset(row: source, column: column)]
        }
        screen.rowIDs[target] = screen.rowIDs[source]
        screen.softWrapped[target] = screen.softWrapped[source]
    }

    private mutating func blankRow(_ screen: inout ScreenStorage, row: Int) {
        for column in 0..<geometry.columns { screen.cells[offset(row: row, column: column)] = .blank }
        screen.rowIDs[row] = allocateLineID()
        screen.softWrapped[row] = false
    }

    private mutating func allocateLineID() -> LineID {
        defer { nextLineRaw &+= 1 }
        return LineID(rawValue: nextLineRaw)
    }

    private func erase(
        _ screen: inout ScreenStorage,
        row: Int,
        columns: ClosedRange<Int>,
        selective: Bool,
        attributes: UInt32
    ) {
        for column in columns {
            let index = offset(row: row, column: column)
            if selective && screen.cells[index].isProtected { continue }
            screen.cells[index] = PackedTerminalCell(
                grapheme: 0, attributes: attributes, span: .narrow, isProtected: false
            )
        }
        normalizeWideCells(&screen, row: row)
    }

    private func shiftRight(_ screen: inout ScreenStorage, row: Int, column: Int, count: Int) {
        let amount = min(count, geometry.columns - column)
        guard amount > 0 else { return }
        let start = offset(row: row, column: 0)
        if column + amount < geometry.columns {
            for target in stride(from: geometry.columns - 1, through: column + amount, by: -1) {
                screen.cells[start + target] = screen.cells[start + target - amount]
            }
        }
        for target in column..<(column + amount) { screen.cells[start + target] = .blank }
        normalizeWideCells(&screen, row: row)
    }

    private func clearWideCell(at row: Int, column: Int, screen: inout ScreenStorage) {
        let index = offset(row: row, column: column)
        if screen.cells[index].span == .continuation, column > 0 { screen.cells[index - 1] = .blank }
        if screen.cells[index].span == .wide, column + 1 < geometry.columns { screen.cells[index + 1] = .blank }
    }

    private func normalizeWideCells(_ screen: inout ScreenStorage, row: Int) {
        let start = offset(row: row, column: 0)
        for column in 0..<geometry.columns {
            let index = start + column
            if screen.cells[index].span == .continuation {
                if column == 0 || screen.cells[index - 1].span != .wide { screen.cells[index] = .blank }
            } else if screen.cells[index].span == .wide {
                if column + 1 >= geometry.columns
                    || screen.cells[index + 1].span != .continuation
                {
                    screen.cells[index] = .blank
                }
            }
        }
    }
}
