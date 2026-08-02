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
    /// Monotonic count of bells received, so a consumer can tell a new one
    /// from a repeat without the engine deciding how to express it.
    private var bellCount: UInt64 = 0
    private var scrollOffset = 0
    private var responseBuffer: [UInt8] = []
    private var tabStops: Set<Int> = []
    private var hyperlinks: [String: UInt32] = [:]
    private var nextHyperlinkID: UInt32 = 1
    private var palette: [UInt8: String] = [:]
    private var lastPrintedGrapheme: String?

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

    /// The colours a program can ask about. The application keeps the defaults
    /// in step with the theme so a query is answered with what is really on
    /// screen, not a guess.
    public var dynamicColors = DynamicColors()
    private var paletteOverrides: [UInt8: DynamicColors.RGB] = [:]
    /// Recorded for the application to act on, and for tests to assert.
    public private(set) var clipboardWrites: [(selection: String, base64: String)] = []
    public private(set) var clipboardReadsRefused = 0
    public private(set) var notifications: [(title: String, body: String)] = []
    public var fontName: String = "Menlo"
    public private(set) var pointerShape: String?

    public var pendingResponses: [UInt8] {
        let responses = responseBuffer
        responseBuffer.removeAll(keepingCapacity: true)
        return responses
    }

    public func consume(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        Perf.consumeCalls += 1
        Perf.consumeBytes += bytes.count
        let consumeStart = DispatchTime.now().uptimeNanoseconds
        defer { Perf.consumeNanos &+= DispatchTime.now().uptimeNanoseconds &- consumeStart }
        var changed = false
        var index = bytes.startIndex
        while index < bytes.endIndex {
            // Ordinary text is nearly all of what arrives. Take it in runs.
            if recognizer.acceptsPlainRun, bytes[index] >= 0x20, bytes[index] < 0x7F {
                var end = index
                while end < bytes.endIndex, bytes[end] >= 0x20, bytes[end] < 0x7F { end += 1 }
                printPlainRun(bytes[index ..< end])
                changed = true
                index = end
                continue
            }
            recognizer.consume(bytes[index]) { [self] operation in
                Perf.opCalls += 1
                apply(operation)
                changed = true
            }
            index += 1
        }
        if changed { publishGeneration() }
    }

    /// The rows a resized viewport should show.
    ///
    /// Taking the last `rows` lines looks right but is not: when a screen has
    /// blank space below the cursor, shrinking pushes live content up into
    /// scrollback and growing pulls it back. A shell that redraws its prompt on
    /// SIGWINCH — which Powerlevel10k and friends do — then has its old prompt
    /// restored above the new one, and the user sees it twice. Real terminals
    /// spend the trailing blank rows first, so content stays put and only the
    /// empty space below it changes size.
    static func viewportRange(
        in lines: [GridLine], rows: Int, cursorLine: LineID
    ) -> Range<Int> {
        guard !lines.isEmpty else { return 0 ..< 0 }
        let lastContent =
            lines.lastIndex { line in
                line.id == cursorLine
                    || line.cells.contains { $0.span != .continuation && $0.grapheme != 0 }
            } ?? lines.count - 1
        // Take a full viewport where one exists, starting no later than the
        // content, so shrinking spends the blank rows below rather than
        // evicting live lines into scrollback.
        let end = min(lines.count, max(lastContent + 1, rows))
        return max(0, end - rows) ..< end
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
        // Viewport and history are two halves of one split, so they are cut at
        // the same index. Deriving history by dropping from the end instead
        // trims the trailing blanks and leaves the lines above the viewport in
        // both places.
        let activeRange = Self.viewportRange(
            in: activeReflow, rows: newGeometry.rows, cursorLine: cursorLine)
        let activeViewport = Array(activeReflow[activeRange])
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
            history = Array(activeReflow[0 ..< activeRange.lowerBound])
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
        Perf.snapshotCalls += 1
        let snapshotStart = DispatchTime.now().uptimeNanoseconds
        defer {
            Perf.snapshotNanos &+= DispatchTime.now().uptimeNanoseconds &- snapshotStart
        }
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
            bellCount: bellCount,
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
        case let .reportTitle(terminator):
            responseBuffer += Array(("\u{1B}]21;" + (title ?? "") + terminator.text).utf8)
        case .setWorkingDirectory(let value): commandReducer.setWorkingDirectory(value)
        case .setHyperlink(let parameters, let uri): setHyperlink(parameters: parameters, uri: uri)
        case .commandMarker(let marker): commandReducer.apply(marker, line: currentLineID)
        case .setPalette(let index, let value):
            palette[index] = value
            if let color = DynamicColors.RGB.parse(value) { paletteOverrides[index] = color }
            damage.fullRedraw = true
        case let .setDynamicColor(slot, value):
            if let slot = DynamicColors.Slot(rawValue: slot),
                let color = DynamicColors.RGB.parse(value)
            {
                dynamicColors.set(slot, to: color)
            }
            damage.fullRedraw = true
        case let .resetDynamicColor(slot):
            if let slot = DynamicColors.Slot(rawValue: slot) { dynamicColors.reset(slot) }
            damage.fullRedraw = true
        case let .reportDynamicColor(slot, terminator):
            guard let slot = DynamicColors.Slot(rawValue: slot) else { break }
            responseBuffer += dynamicColors.reply(for: slot, terminator: terminator)
        case let .reportPaletteColor(index, terminator):
            let color = paletteOverrides[index] ?? DynamicColors.RGB(0, 0, 0)
            responseBuffer += Array(
                ("\u{1B}]4;\(index);" + color.xtermDescription + terminator.text).utf8)
        case let .resetPalette(index):
            if let index { paletteOverrides.removeValue(forKey: index) }
            else { paletteOverrides.removeAll() }
            damage.fullRedraw = true
        case let .clipboard(selection, base64):
            // Writing is ordinary. Reading is not: a program that can read the
            // clipboard unprompted can read whatever the user last copied, so
            // the request is recorded and refused, as every serious terminal
            // refuses it by default.
            if let base64 { clipboardWrites.append((selection, base64)) }
            else { clipboardReadsRefused += 1 }
        case let .notification(title, body):
            notifications.append((title, body))
        case let .setPointerShape(shape):
            pointerShape = shape.isEmpty ? nil : shape
        case let .setFont(name):
            if !name.isEmpty { fontName = name }
        case let .reportFont(terminator):
            responseBuffer += Array(("\u{1B}]50;" + fontName + terminator.text).utf8)
        case .respond(let bytes): responseBuffer += bytes
        case .reset: reset()
        case .reportCursorPosition(let privateMode):
            if privateMode {
                responseBuffer += Array(
                    "\u{1B}[?\(grid.cursor.row + 1);\(grid.cursor.column + 1);1R".utf8
                )
            } else {
                responseBuffer += Array(
                    "\u{1B}[\(grid.cursor.row + 1);\(grid.cursor.column + 1)R".utf8
                )
            }
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
        case let .reportMode(mode, isPrivate):
            let pm = reportModeStatus(mode: mode, isPrivate: isPrivate)
            let prefix = isPrivate ? "\u{1B}[?" : "\u{1B}["
            responseBuffer += Array("\(prefix)\(mode);\(pm)$y".utf8)
        case .reportTerminalVersion:
            responseBuffer += Array("\u{1B}P>|Allward(0.1.0)\u{1B}\\".utf8)
        case let .setCursorStyle(style):
            modes.cursorStyle = style
        case .setHorizontalMargins:
            break
        case let .repeatCharacter(count):
            if let last = lastPrintedGrapheme {
                for _ in 0 ..< min(max(1, count), geometry.columns * geometry.rows) {
                    applyPrintable(last)
                }
            }
        case .softReset:
            modes.originMode = false
            modes.autoWrap = true
            modes.insertMode = false
            modes.applicationCursorKeys = false
            modes.applicationKeypad = false
            modes.reverseVideo = false
            modes.bracketedPaste = false
            modes.mouseTracking = .off
            modes.mouseEncoding = .x10
            modes.focusReporting = false
            modes.synchronizedOutput = false
            modes.cursorStyle = .blinkingBlock
            grid.setCursorVisible(true)
            grid.setMargins(top: 1, bottom: geometry.rows)
            grid.setCurrentAttributes(.default)
        case let .reportSetting(setting):
            switch setting {
            case "m":
                responseBuffer += Array("\u{1B}P1$r0m\u{1B}\\".utf8)
            case "r":
                let top = grid.scrollTop + 1
                let bottom = grid.scrollBottom + 1
                responseBuffer += Array("\u{1B}P1$r\(top);\(bottom)r\u{1B}\\".utf8)
            case "s":
                responseBuffer += Array("\u{1B}P1$r1;\(geometry.columns)s\u{1B}\\".utf8)
            case "\"q", " q":
                let style = modes.cursorStyle.rawValue
                responseBuffer += Array("\u{1B}P1$r\(style) \" q\u{1B}\\".utf8)
            default:
                responseBuffer += Array("\u{1B}P0$r\(setting)\u{1B}\\".utf8)
            }
        case .reportTermcap:
            responseBuffer += Array("\u{1B}P0+r\u{1B}\\".utf8)
        case .noOp: break
        }
        damage.cursorMoved = damage.cursorMoved || initialRow != grid.cursor.row
        markRow(grid.cursor.row)
    }

    /// Writes a run of printable ASCII without going through the parser.
    ///
    /// Printable ASCII is always width 1, never combines and never attaches, so
    /// none of the cluster machinery can change the answer. Taking it as a run
    /// removes a String allocation, an enum box and a closure call per byte.
    private func printPlainRun(_ bytes: ArraySlice<UInt8>) {
        Perf.opCalls += bytes.count
        var references = [UInt32]()
        references.reserveCapacity(bytes.count)
        for byte in bytes { references.append(graphemes.internASCII(byte)) }
        let current = grid.currentAttributes
        let scrolled = grid.printRun(
            graphemes: references,
            attributes: attributes.intern(current),
            protected: current.flags.contains(.protected),
            autoWrap: modes.autoWrap
        )
        appendScrollback(scrolled)
        commandReducer.appendCommandInput(String(decoding: bytes, as: UTF8.self))
        markRegion()
        if let lastByte = bytes.last { lastPrintedGrapheme = String(UnicodeScalar(lastByte)) }
    }

    /// Printing one plain character used to cost about 7.7 microseconds.
    ///
    /// The slow path rebuilds the previous cluster as a `String`, concatenates
    /// it with the new scalar and asks Swift to count graphemes over the
    /// result, resolves width, then interns the character by hashing a String.
    /// All of that exists for combining marks, emoji sequences and wide
    /// characters, and none of it can change the answer for printable ASCII: it
    /// is always width 1, never combines, and never attaches to what precedes
    /// it. So ASCII takes none of it.
    private func printASCII(_ byte: UInt8, text: String) {
        let reference = graphemes.internASCII(byte)
        let current = grid.currentAttributes
        let scrolled = grid.print(
            grapheme: reference,
            width: 1,
            attributes: attributes.intern(current),
            protected: current.flags.contains(.protected),
            autoWrap: modes.autoWrap,
            insertMode: modes.insertMode
        )
        appendScrollback(scrolled)
        commandReducer.appendCommandInput(text)
    }

    private func applyPrintable(_ text: String) {
        lastPrintedGrapheme = text
        guard let scalar = text.unicodeScalars.first else { return }
        if scalar.value >= 0x20, scalar.value < 0x7F, text.utf8.count == 1 {
            printASCII(UInt8(scalar.value), text: text)
            return
        }
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
            grapheme: reference,
            width: resolved.width,
            attributes: attributes.intern(current),
            protected: current.flags.contains(.protected),
            autoWrap: modes.autoWrap,
            insertMode: modes.insertMode
        )
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
        case .bell:
            // The bell is a real signal a program sends, not noise to discard.
            // The engine only records it; how it is expressed is the app's
            // decision, because a bell must also be visible to be accessible.
            bellCount &+= 1
        case .shiftIn, .shiftOut: break
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
        case .reverseVideo: modes.reverseVideo = enabled; damage.fullRedraw = true
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
        case .utf8Mouse, .urxvtMouse, .pixelMouse: break
        case .cursorBlink: break
        }
    }
    private func reportModeStatus(mode: Int, isPrivate: Bool) -> Int {
        if isPrivate {
            switch mode {
            case 1: return modes.applicationCursorKeys ? 1 : 2
            case 5: return modes.reverseVideo ? 1 : 2
            case 6: return modes.originMode ? 1 : 2
            case 7: return modes.autoWrap ? 1 : 2
            case 12: return 2
            case 25: return grid.cursor.visible ? 1 : 2
            case 47, 1047, 1049: return modes.alternateScreen ? 1 : 2
            case 1000: return modes.mouseTracking == .pressRelease ? 1 : 2
            case 1002: return modes.mouseTracking == .buttonMotion ? 1 : 2
            case 1003: return modes.mouseTracking == .anyMotion ? 1 : 2
            case 1004: return modes.focusReporting ? 1 : 2
            case 1005, 1015, 1016: return 2
            case 1006: return modes.mouseEncoding == .sgr ? 1 : 2
            case 2004: return modes.bracketedPaste ? 1 : 2
            case 2026: return modes.synchronizedOutput ? 1 : 2
            default: return 0
            }
        } else {
            switch mode {
            case 4: return modes.insertMode ? 1 : 2
            default: return 0
            }
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

    /// Tab motion, with the repeat count bounded by the row.
    ///
    /// `ESC [ 9223372036854775807 I` looped that many times, pinning the
    /// session actor forever. There are at most `columns` tab stops to cross,
    /// so anything beyond that is the same answer reached more slowly.
    private func moveTabs(forward: Bool, count: Int) {
        var column = grid.cursor.column
        for _ in 0 ..< min(max(1, count), max(1, geometry.columns)) {
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
        pointerShape = nil
        bellCount = 0
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
