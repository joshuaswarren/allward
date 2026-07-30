import AllwardCore
import Foundation

public final class Terminal {
    private var geometry: TerminalGeometry
    private let clock: any AllwardClock
    private var recognizer = EscapeRecognizer()
    private var grid: Grid
    private var scrollback: Scrollback
    private var graphemes = GraphemeTable()
    private var attributes = AttributeTable()
    private var resolver = GraphemeResolver()
    private var commandReducer: CommandRegionReducer
    private var modes = TerminalModes()
    private var selection: Selection?
    private var generation = Generation.initial
    private var damage = Damage.full
    private var title: String?
    private var scrollOffset = 0
    private var responseBuffer: [UInt8] = []
    private var tabStops: Set<Int> = []
    private var hyperlinks: [String: UInt32] = [:]
    private var nextHyperlinkID: UInt32 = 1
    private var palette: [UInt8: String] = [:]

    public init(
        geometry: TerminalGeometry,
        clock: any AllwardClock,
        scrollbackCapacity: Int = 10_000
    ) {
        self.geometry = geometry
        self.clock = clock
        grid = Grid(geometry: geometry)
        scrollback = Scrollback(capacity: scrollbackCapacity)
        commandReducer = CommandRegionReducer(clock: clock)
        resetTabStops()
    }

    public var pendingResponses: [UInt8] {
        let responses = responseBuffer
        responseBuffer.removeAll(keepingCapacity: true)
        return responses
    }

    public func consume(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        var changed = false
        for byte in bytes {
            recognizer.consume(byte) { [self] operation in
                apply(operation)
                changed = true
            }
        }
        if changed { publishGeneration() }
    }

    public func resize(to newGeometry: TerminalGeometry) {
        guard newGeometry != geometry else { return }
        let oldColumnCount = geometry.columns
        let liveRows = grid.packedRows()
        let cursor = grid.cursor
        var logicalStartRow = cursor.row
        while logicalStartRow > 0 && !liveRows[logicalStartRow - 1].hardBreak {
            logicalStartRow -= 1
        }
        let cursorLine = liveRows[logicalStartRow].id
        let offscreenOffset = modes.alternateScreen ? 0 : scrollback.lines
            .filter { $0.id == cursorLine }
            .reduce(0) { $0 + $1.cells.filter { $0.span != .continuation }.count }
        let visibleOffset = liveRows[logicalStartRow..<cursor.row].reduce(0) {
            $0 + $1.cells.filter { $0.span != .continuation }.count
        }
        let cursorOffset = offscreenOffset
            + visibleOffset
            + graphemeOffset(in: liveRows[cursor.row].cells, throughColumn: cursor.column)
        let cursorAnchor = SelectionAnchor(line: cursorLine, graphemeOffset: cursorOffset)
        let activeSource = modes.alternateScreen ? liveRows : scrollback.lines + liveRows
        let activeReflow = reflow(activeSource, columns: newGeometry.columns)
        let activeViewport = Array(activeReflow.suffix(newGeometry.rows))
        var inactiveViewport: [GridLine]?
        let history: [GridLine]
        if modes.alternateScreen {
            let primaryReflow = reflow(
                scrollback.lines + grid.primaryRows(),
                columns: newGeometry.columns
            )
            history = Array(primaryReflow.dropLast(min(newGeometry.rows, primaryReflow.count)))
            inactiveViewport = Array(primaryReflow.suffix(newGeometry.rows))
        } else {
            history = Array(activeReflow.dropLast(min(newGeometry.rows, activeReflow.count)))
        }
        let hiddenCursorOffset = history.filter { $0.id == cursorAnchor.line }.reduce(0) {
            $0 + $1.cells.filter { $0.span != .continuation }.count
        }
        let viewportCursorAnchor = SelectionAnchor(
            line: cursorAnchor.line,
            graphemeOffset: max(0, cursorAnchor.graphemeOffset - hiddenCursorOffset)
        )
        let evicted = scrollback.replace(with: history)
        geometry = newGeometry
        grid.replaceForResize(
            rows: activeViewport,
            inactiveRows: inactiveViewport,
            geometry: newGeometry,
            cursorAnchor: viewportCursorAnchor
        )
        invalidate(lines: evicted)
        if let selection,
           !containsLine(selection.start.line) || !containsLine(selection.end.line)
        {
            self.selection = nil
            damage.selectionChanged = true
        }
        scrollOffset = min(scrollOffset, scrollback.count)
        tabStops = Set(tabStops.filter { $0 < newGeometry.columns })
        for column in stride(from: 8, to: newGeometry.columns, by: 8) where column >= oldColumnCount {
            tabStops.insert(column)
        }
        damage = .full
        publishGeneration()
    }

    public func setSelection(_ newSelection: Selection?) {
        if let newSelection,
           !containsLine(newSelection.start.line) || !containsLine(newSelection.end.line)
        {
            selection = nil
        } else {
            selection = newSelection
        }
        damage.selectionChanged = true
        publishGeneration()
    }

    public func scroll(toOffset offset: Int) {
        let clamped = min(max(0, offset), scrollback.count)
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        damage.fullRedraw = true
        publishGeneration()
    }

    public func snapshot() -> TerminalSnapshot {
        let liveRows = grid.packedRows()
        let visibleLines: [GridLine]
        if scrollOffset == 0 {
            visibleLines = liveRows
        } else {
            let combined = scrollback.lines + liveRows
            let end = max(0, combined.count - scrollOffset)
            let start = max(0, end - geometry.rows)
            visibleLines = Array(combined[start..<end])
        }
        let missing = max(0, geometry.rows - visibleLines.count)
        let blankRow = Array(repeating: TerminalCell.blank, count: geometry.columns)
        let rows = Array(repeating: blankRow, count: missing) + visibleLines.map(materialize)
        let blankIDs = Array(repeating: LineID(rawValue: 0), count: missing)
        let snapshot = TerminalSnapshot(
            generation: generation,
            geometry: geometry,
            rows: rows,
            rowIDs: blankIDs + visibleLines.map(\.id),
            cursor: grid.cursor,
            modes: modes,
            selection: selection,
            damage: normalizedDamage(),
            title: title,
            scrollbackCount: scrollback.count,
            scrollOffset: scrollOffset,
            commandRegions: commandReducer.regions,
            imagePlacements: []
        )
        damage = .none
        return snapshot
    }

    public func selectedText() -> String? {
        guard let selection else { return nil }
        let allLines = scrollback.lines + grid.packedRows()
        let logicalIDs = uniqueLineIDs(in: allLines)
        guard let startIndex = logicalIDs.firstIndex(of: selection.start.line),
              let endIndex = logicalIDs.firstIndex(of: selection.end.line)
        else { return nil }
        let forward = startIndex <= endIndex
        let lowerAnchor = forward ? selection.start : selection.end
        let upperAnchor = forward ? selection.end : selection.start
        let selectedIDs = logicalIDs[min(startIndex, endIndex)...max(startIndex, endIndex)]
        var chunks: [String] = []
        for id in selectedIDs {
            let graphemes = logicalGraphemes(for: id, in: allLines)
            let lower = id == lowerAnchor.line ? max(0, lowerAnchor.graphemeOffset) : 0
            let upper = id == upperAnchor.line ? min(graphemes.count, upperAnchor.graphemeOffset) : graphemes.count
            if lower <= upper { chunks.append(graphemes[lower..<upper].joined()) }
        }
        return chunks.joined(separator: "\n")
    }

    private func apply(_ operation: TerminalOperation) {
        let initialRow = grid.cursor.row
        switch operation {
        case .print(let text): applyPrintable(text)
        case .control(let control): applyControl(control)
        case .cursorUp(let count): grid.moveVertical(-count, originMode: modes.originMode)
        case .cursorDown(let count): grid.moveVertical(count, originMode: modes.originMode)
        case .cursorForward(let count): grid.moveHorizontal(count)
        case .cursorBackward(let count): grid.moveHorizontal(-count)
        case .cursorNextLine(let count):
            grid.moveVertical(count, originMode: modes.originMode)
            grid.carriageReturn()
        case .cursorPreviousLine(let count):
            grid.moveVertical(-count, originMode: modes.originMode)
            grid.carriageReturn()
        case .cursorHorizontalAbsolute(let column): grid.horizontalAbsolute(column)
        case .cursorVerticalAbsolute(let row): grid.verticalAbsolute(row, originMode: modes.originMode)
        case .cursorPosition(let row, let column): grid.position(row: row, column: column, originMode: modes.originMode)
        case .eraseDisplay(let mode, let selective):
            grid.eraseDisplay(mode, selective: selective, attributes: attributes.intern(grid.currentAttributes))
            if mode == .scrollback { invalidate(lines: scrollback.removeAll()) }
            markAllRows()
        case .eraseLine(let mode, let selective):
            grid.eraseLine(mode, selective: selective, attributes: attributes.intern(grid.currentAttributes))
        case .eraseCharacters(let count):
            grid.eraseCharacters(count, selective: false, attributes: attributes.intern(grid.currentAttributes))
        case .insertCharacters(let count): grid.insertCharacters(count)
        case .deleteCharacters(let count): grid.deleteCharacters(count)
        case .insertLines(let count): grid.insertLines(count); markRegion()
        case .deleteLines(let count): grid.deleteLines(count); markRegion()
        case .setInsertMode(let enabled): modes.insertMode = enabled
        case .setApplicationKeypad(let enabled): modes.applicationKeypad = enabled
        case .scrollUp(let count): appendScrollback(grid.scrollUp(count)); markRegion()
        case .scrollDown(let count): grid.scrollDown(count); markRegion()
        case .setVerticalMargins(let top, let bottom):
            grid.setMargins(top: top, bottom: bottom)
            grid.position(row: 1, column: 1, originMode: modes.originMode)
        case .ignoreHorizontalMargins: break
        case .saveCursor: grid.saveCursor(originMode: modes.originMode)
        case .restoreCursor:
            if let origin = grid.restoreCursor() { modes.originMode = origin }
        case .sgr(let parameters): applySGR(parameters)
        case .setModes(let modeValues): for mode in modeValues { setMode(mode, enabled: true) }
        case .resetModes(let modeValues): for mode in modeValues { setMode(mode, enabled: false) }
        case .setTabStop: tabStops.insert(grid.cursor.column)
        case .clearTabStop(let mode):
            if mode == .current {
                tabStops.remove(grid.cursor.column)
            } else {
                tabStops.removeAll(keepingCapacity: true)
            }
        case .cursorForwardTab(let count): moveTabs(forward: true, count: count)
        case .cursorBackwardTab(let count): moveTabs(forward: false, count: count)
        case .setTitle(let value): title = value
        case .setWorkingDirectory(let value): commandReducer.setWorkingDirectory(value)
        case .setHyperlink(let parameters, let uri): setHyperlink(parameters: parameters, uri: uri)
        case .commandMarker(let marker): commandReducer.apply(marker, line: currentLineID)
        case .setPalette(let index, let value): palette[index] = value; damage.fullRedraw = true
        case .setDynamicColor: damage.fullRedraw = true
        case .respond(let bytes): responseBuffer += bytes
        case .reset: reset()
        case .reportCursorPosition(let privateMode):
            let prefix = privateMode ? "\u{1B}[?" : "\u{1B}["
            responseBuffer += Array(
                "\(prefix)\(grid.cursor.row + 1);\(grid.cursor.column + 1)R".utf8
            )
        case .alignmentTest:
            let reference = graphemes.intern("E")
            grid.alignmentTest(grapheme: reference, attributes: attributes.intern(grid.currentAttributes))
            markAllRows()
        case .index: appendScrollback(grid.lineFeed())
        case .reverseIndex: grid.reverseIndex(); markRegion()
        case .nextLine: appendScrollback(grid.nextLine())
        case .setProtection(let enabled):
            var current = grid.currentAttributes
            if enabled { current.flags.insert(.protected) } else { current.flags.remove(.protected) }
            grid.setCurrentAttributes(current)
        case .noOp: break
        }
        damage.cursorMoved = damage.cursorMoved || initialRow != grid.cursor.row
        markRow(grid.cursor.row)
    }

    private func applyPrintable(_ text: String) {
        guard let scalar = text.unicodeScalars.first else { return }
        let previous = grid.previousClusterText(graphemes: graphemes)
        if resolver.shouldAttach(scalar, to: previous) {
            let resolved = resolver.resolve(previous + text)
            if let row = grid.attachToPrevious(
                scalar,
                width: resolved.width,
                autoWrap: modes.autoWrap,
                graphemes: &graphemes
            ) {
                markRow(row)
            }
            commandReducer.appendCommandInput(text)
            return
        }
        let printable = resolver.isCombining(scalar) ? " " + text : text
        let resolved = resolver.resolve(printable)
        let reference = graphemes.intern(resolved.text)
        let current = grid.currentAttributes
        let scrolled = grid.print(
            width: resolved.width,
            attributes: attributes.intern(current),
            protected: current.flags.contains(.protected),
            autoWrap: modes.autoWrap,
            insertMode: modes.insertMode
        )
        grid.replaceSentinelGrapheme(with: reference)
        appendScrollback(scrolled)
        commandReducer.appendCommandInput(text)
    }


    private func applyControl(_ control: C0Control) {
        commandReducer.control(control)
        switch control {
        case .backspace: grid.backspace()
        case .horizontalTab: moveTabs(forward: true, count: 1)
        case .lineFeed, .verticalTab, .formFeed: appendScrollback(grid.lineFeed())
        case .carriageReturn: grid.carriageReturn()
        case .bell, .shiftIn, .shiftOut: break
        }
    }

    private func applySGR(_ parameters: [SGRParameter]) {
        var current = grid.currentAttributes
        for parameter in parameters {
            switch parameter {
            case .reset:
                let protection = current.flags.intersection(.protected)
                current = .default
                current.flags.formUnion(protection)
            case .flag(let flag, let enabled):
                if enabled { current.flags.insert(flag) } else { current.flags.remove(flag) }
            case .foreground(let color): current.foreground = color
            case .background(let color): current.background = color
            case .underlineColor(let color): current.underlineColor = color
            }
        }
        grid.setCurrentAttributes(current)
    }

    private func setMode(_ mode: TerminalMode, enabled: Bool) {
        switch mode {
        case .applicationCursorKeys: modes.applicationCursorKeys = enabled
        case .origin:
            modes.originMode = enabled
            grid.position(row: 1, column: 1, originMode: enabled)
        case .autoWrap: modes.autoWrap = enabled
        case .cursorVisible: grid.setCursorVisible(enabled)
        case .alternateScreen:
            _ = grid.setAlternate(enabled, clear: false, savePrimary: false, originMode: modes.originMode)
            modes.alternateScreen = enabled
            damage.fullRedraw = true
        case .alternateScreen1047:
            _ = grid.setAlternate(enabled, clear: enabled, savePrimary: false, originMode: modes.originMode)
            modes.alternateScreen = enabled
            damage.fullRedraw = true
        case .saveCursor:
            if enabled { grid.saveCursor(originMode: modes.originMode) }
            else if let origin = grid.restoreCursor() { modes.originMode = origin }
        case .alternateScreen1049:
            if let origin = grid.setAlternate(
                enabled,
                clear: enabled,
                savePrimary: true,
                originMode: modes.originMode
            ) {
                modes.originMode = origin
            }
            modes.alternateScreen = enabled
            damage.fullRedraw = true
        case .bracketedPaste: modes.bracketedPaste = enabled
        case .mousePress: modes.mouseTracking = enabled ? .pressRelease : .off
        case .mouseButtonMotion: modes.mouseTracking = enabled ? .buttonMotion : .off
        case .mouseAnyMotion: modes.mouseTracking = enabled ? .anyMotion : .off
        case .focusReporting: modes.focusReporting = enabled
        case .sgrMouse: modes.mouseEncoding = enabled ? .sgr : .x10
        case .synchronizedOutput: modes.synchronizedOutput = enabled
        case .cursorBlink: break
        }
    }

    private func setHyperlink(parameters: String, uri: String?) {
        var current = grid.currentAttributes
        if let uri {
            let key = parameters + "\u{0}" + uri
            if let existing = hyperlinks[key] { current.hyperlinkID = existing }
            else {
                current.hyperlinkID = nextHyperlinkID
                hyperlinks[key] = nextHyperlinkID
                nextHyperlinkID &+= 1
            }
        } else { current.hyperlinkID = nil }
        grid.setCurrentAttributes(current)
    }

    private func moveTabs(forward: Bool, count: Int) {
        var column = grid.cursor.column
        for _ in 0..<max(1, count) {
            if forward { column = tabStops.filter { $0 > column }.min() ?? geometry.columns - 1 }
            else { column = tabStops.filter { $0 < column }.max() ?? 0 }
        }
        grid.horizontalAbsolute(column + 1)
    }

    private func appendScrollback(_ lines: [GridLine]) {
        guard !grid.alternateActive,
              grid.scrollTop == 0,
              grid.scrollBottom == geometry.rows - 1
        else { return }
        for line in lines {
            if let evicted = scrollback.append(line) { invalidate(lines: [evicted]) }
        }
        scrollOffset = min(scrollOffset, scrollback.count)
    }

    private func invalidate(lines: [LineID]) {
        guard let selection else { return }
        let startEvicted = lines.contains(selection.start.line) && !containsLine(selection.start.line)
        let endEvicted = lines.contains(selection.end.line) && !containsLine(selection.end.line)
        if startEvicted || endEvicted {
            self.selection = nil
            damage.selectionChanged = true
        }
    }

    private func containsLine(_ id: LineID) -> Bool {
        scrollback.contains(id)
            || grid.rowIDs.contains(id)
            || grid.primaryRows().contains { $0.id == id }
    }

    private var currentLineID: LineID { grid.rowIDs[grid.cursor.row] }

    private func reset() {
        grid = Grid(geometry: geometry)
        scrollback = Scrollback(capacity: scrollback.capacity)
        graphemes.reset()
        attributes.reset()
        commandReducer.reset()
        modes = TerminalModes()
        selection = nil
        title = nil
        scrollOffset = 0
        hyperlinks.removeAll(keepingCapacity: true)
        nextHyperlinkID = 1
        palette.removeAll(keepingCapacity: true)
        resetTabStops()
        damage = .full
    }

    private func resetTabStops() {
        tabStops = Set(stride(from: 8, to: geometry.columns, by: 8))
    }

    private func publishGeneration() { generation = generation.next }
    private func markRow(_ row: Int) { damage.rows.append(row..<(row + 1)) }
    private func markRegion() { damage.rows.append(grid.scrollTop..<(grid.scrollBottom + 1)) }
    private func markAllRows() { damage.rows.append(0..<geometry.rows) }

    private func normalizedDamage() -> Damage {
        guard !damage.fullRedraw, !damage.rows.isEmpty else { return damage }
        let sorted = damage.rows.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        var result = damage
        result.rows = merged
        return result
    }

    private func materialize(_ line: GridLine) -> [TerminalCell] {
        var row = line.cells.map {
            TerminalCell(text: graphemes[$0.grapheme], attributes: attributes[$0.attributes], span: $0.span)
        }
        if row.count < geometry.columns {
            row += Array(repeating: .blank, count: geometry.columns - row.count)
        } else if row.count > geometry.columns { row.removeLast(row.count - geometry.columns) }
        return row
    }

    private func reflow(_ lines: [GridLine], columns: Int) -> [GridLine] {
        var logical: [(LineID, [PackedTerminalCell])] = []
        var currentID: LineID?
        var currentCells: [PackedTerminalCell] = []
        for line in lines {
            if currentID == nil { currentID = line.id }
            var cells = line.cells
            if line.hardBreak {
                while cells.last == .blank { cells.removeLast() }
            }
            currentCells += cells
            if line.hardBreak {
                logical.append((currentID ?? line.id, currentCells))
                currentID = nil
                currentCells = []
            }
        }
        if let currentID { logical.append((currentID, currentCells)) }
        var result: [GridLine] = []
        for (id, cells) in logical {
            if cells.isEmpty { result.append(GridLine(id: id, cells: [], hardBreak: true)); continue }
            var start = 0
            while start < cells.count {
                var end = min(cells.count, start + columns)
                if end < cells.count, cells[end].span == .continuation { end -= 1 }
                if end == start { end = min(cells.count, start + columns) }
                result.append(GridLine(id: id, cells: Array(cells[start..<end]), hardBreak: end == cells.count))
                start = end
            }
        }
        return result
    }

    private func graphemeOffset(in cells: [PackedTerminalCell], throughColumn column: Int) -> Int {
        cells.prefix(min(cells.count, max(0, column))).filter { $0.span != .continuation }.count
    }

    private func uniqueLineIDs(in lines: [GridLine]) -> [LineID] {
        var seen: Set<LineID> = []
        return lines.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }

    private func logicalGraphemes(for id: LineID, in lines: [GridLine]) -> [String] {
        lines.filter { $0.id == id }.flatMap { line in
            line.cells.compactMap { cell in cell.span == .continuation ? nil : graphemes[cell.grapheme] }
        }
    }
}
