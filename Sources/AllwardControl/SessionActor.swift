import AllwardCore
import AllwardRemote
import AllwardTerminal
import Foundation

public actor Session {
    public nonisolated let id: SessionID
    public nonisolated let latest: AsyncStream<TerminalSnapshot>

    private let terminal: Terminal
    private let channel: any RemoteChannel
    private let continuation: AsyncStream<TerminalSnapshot>.Continuation
    private var ingestionTask: Task<Void, Never>?
    private var closed = false
    private var writable = false

    public init(
        id: SessionID = SessionID(),
        channel: any RemoteChannel,
        geometry: TerminalGeometry,
        clock: any AllwardClock,
        scrollbackCapacity: Int = 10_000
    ) {
        self.id = id
        self.channel = channel
        terminal = Terminal(
            geometry: geometry,
            clock: clock,
            scrollbackCapacity: scrollbackCapacity
        )
        let pair = AsyncStream.makeStream(
            of: TerminalSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        latest = pair.stream
        continuation = pair.continuation
    }

    public func start() {
        guard !closed, ingestionTask == nil else { return }
        continuation.yield(terminal.snapshot())
        let events = channel.events
        ingestionTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.ingest(event)
            }
        }
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard !closed, writable, !bytes.isEmpty else { return false }
        channel.write(bytes)
        return true
    }

    @discardableResult
    public func paste(_ text: String) -> Bool {
        guard !closed, writable, !text.isEmpty else { return false }
        let modes = terminal.snapshot().modes
        channel.write(InputEncoder.paste(text, modes: modes))
        return true
    }

    public func resize(columns: Int, rows: Int) {
        guard !closed, writable else { return }
        let geometry = TerminalGeometry(columns: columns, rows: rows)
        terminal.resize(to: geometry)
        channel.resize(columns: geometry.columns, rows: geometry.rows)
        continuation.yield(terminal.snapshot())
    }

    public func setSelection(_ selection: Selection?) {
        terminal.setSelection(selection)
    }

    /// Scroll by a signed row delta. Positive scrolls back into history; the
    /// terminal clamps the offset to the retained scrollback.
    public func scroll(byRows rows: Int) {
        let current = terminal.snapshot().scrollOffset
        terminal.scroll(toOffset: max(0, current + rows))
    }

    public func selectedText() -> String? { terminal.selectedText() }

    /// Tells the engine what the theme actually paints, so `OSC 10/11/12`
    /// queries are answered with the colours on screen rather than a default.
    /// A TUI that cannot read the background assumes a light one and picks dark
    /// text, which is invisible on a dark grid.
    public func setReportedColors(
        foreground: DynamicColors.RGB, background: DynamicColors.RGB, cursor: DynamicColors.RGB
    ) {
        terminal.dynamicColors.defaults = [
            .foreground: foreground, .background: background, .cursor: cursor,
        ]
    }

    public func snapshot() -> TerminalSnapshot {
        terminal.snapshot()
    }

    public func commandRegions() -> [CommandRegion] {
        terminal.snapshot().commandRegions
    }

    func isOpen() -> Bool { !closed && writable }

    public func close() {
        guard !closed else { return }
        closed = true
        ingestionTask?.cancel()
        ingestionTask = nil
        channel.close()
        continuation.finish()
    }

    func history(lines requestedLineCount: Int) -> [String] {
        historyEntries(lines: requestedLineCount).map { $0.text }
    }

    func historyEntries(lines requestedLineCount: Int) -> [(line: LineID, text: String)] {
        guard requestedLineCount > 0 else { return [] }
        let original = terminal.snapshot()
        var collected: [LineID: String] = [:]
        var offset = 0
        let maximumOffset = original.scrollbackCount

        while offset <= maximumOffset && collected.count < requestedLineCount {
            terminal.scroll(toOffset: offset)
            let page = terminal.snapshot()
            for (index, lineID) in page.rowIDs.enumerated() where lineID.rawValue != 0 {
                collected[lineID] = page.plainText(row: index)
            }
            if offset == maximumOffset { break }
            offset = min(maximumOffset, offset + page.geometry.rows)
        }

        terminal.scroll(toOffset: original.scrollOffset)
        return collected.keys.sorted().suffix(requestedLineCount).compactMap { lineID in
            collected[lineID].map { (lineID, $0) }
        }
    }

    /// Where a string appears in the scrollback.
    ///
    /// Each hit carries the scroll offset that puts its line on screen, so the
    /// caller can bring a match into view without knowing how the buffer is
    /// paged. Matching is case-insensitive, which is what a terminal's find
    /// does unless told otherwise.
    public func findMatches(of query: String, limit: Int = 500) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let original = terminal.snapshot()
        var matches: [SearchMatch] = []
        var seen: Set<LineID> = []
        var offset = 0
        let maximumOffset = original.scrollbackCount

        while offset <= maximumOffset, matches.count < limit {
            terminal.scroll(toOffset: offset)
            let page = terminal.snapshot()
            for (index, lineID) in page.rowIDs.enumerated()
            where lineID.rawValue != 0 && !seen.contains(lineID) {
                seen.insert(lineID)
                let text = page.plainText(row: index)
                var cursor = text.startIndex
                while let found = text.range(
                    of: query, options: .caseInsensitive, range: cursor ..< text.endIndex)
                {
                    matches.append(
                        SearchMatch(
                            line: lineID,
                            column: text.distance(from: text.startIndex, to: found.lowerBound),
                            length: text.distance(from: found.lowerBound, to: found.upperBound),
                            scrollOffset: offset))
                    cursor = found.upperBound
                    if matches.count >= limit { break }
                }
            }
            if offset == maximumOffset { break }
            offset = min(maximumOffset, offset + page.geometry.rows)
        }

        terminal.scroll(toOffset: original.scrollOffset)
        return matches.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// Puts a match on screen and selects it.
    public func reveal(_ match: SearchMatch) {
        terminal.scroll(toOffset: match.scrollOffset)
        terminal.setSelection(
            Selection(
                start: SelectionAnchor(line: match.line, graphemeOffset: match.column),
                end: SelectionAnchor(
                    line: match.line, graphemeOffset: match.column + match.length),
                mode: .stream))
    }

    func nextFinishedCommand(
        after existing: Set<LineID>,
        timeout: Duration
    ) async -> CommandRegion? {
        let timer = ContinuousClock()
        let deadline = timer.now.advanced(by: timeout)
        while !closed, timer.now < deadline {
            if let region = terminal.snapshot().commandRegions.first(where: {
                !existing.contains($0.id) && $0.phase == .finished
            }) {
                return region
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func encoded(_ keys: [AllwardTerminal.TerminalKey]) -> [UInt8] {
        let modes = terminal.snapshot().modes
        return keys.flatMap { InputEncoder.key($0, modes: modes) }
    }

    private func ingest(_ event: RemoteEvent) {
        guard !closed else { return }
        switch event {
        case let .bytes(bytes):
            terminal.consume(bytes)
            let responses = terminal.pendingResponses
            if !responses.isEmpty { channel.write(responses) }
            continuation.yield(terminal.snapshot())
        case let .state(state, _):
            switch state {
            case .ready, .degraded:
                writable = true
            case .closed:
                writable = false
                closed = true
                ingestionTask = nil
                continuation.finish()
            case .idle, .resolving, .connecting, .authenticating, .reconnecting:
                writable = false
            }
        case .exited, .failed:
            closed = true
            writable = false
            ingestionTask = nil
            continuation.finish()
        }
    }
}
