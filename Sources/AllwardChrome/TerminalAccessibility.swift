import AllwardTerminal
import AppKit

/// A flat text projection of the grid, with the offsets VoiceOver needs.
///
/// The grid is drawn by Metal, so nothing about it reaches assistive technology
/// unless it is described here. A single joined string is not enough: VoiceOver
/// navigates text by line and asks where the insertion point and selection are,
/// and every one of those questions is answered in character offsets. Building
/// the line table once per snapshot keeps those answers cheap.
struct TerminalTextProjection {
    let text: String
    /// Character range of each visible row, in order.
    let lineRanges: [NSRange]
    let cursorLine: Int
    let cursorRange: NSRange
    let selectedRange: NSRange?
    /// UTF-16 offset of each grid column, per row.
    ///
    /// The engine reports the cursor and selection in *cells*, but every
    /// accessibility query is in UTF-16 offsets. A wide CJK glyph occupies two
    /// cells and one character, and a combining mark occupies one cell and
    /// several, so the two coordinate systems drift apart the moment a terminal
    /// shows anything but ASCII. This table converts between them exactly.
    private let columnOffsets: [[Int]]

    static let empty = TerminalTextProjection(
        text: "", lineRanges: [], cursorLine: 0, cursorRange: NSRange(location: 0, length: 0),
        selectedRange: nil, columnOffsets: [])

    init(
        text: String, lineRanges: [NSRange], cursorLine: Int, cursorRange: NSRange,
        selectedRange: NSRange?, columnOffsets: [[Int]] = []
    ) {
        self.text = text
        self.lineRanges = lineRanges
        self.cursorLine = cursorLine
        self.cursorRange = cursorRange
        self.selectedRange = selectedRange
        self.columnOffsets = columnOffsets
    }

    /// The UTF-16 offset each column starts at, walking the row's real cells.
    private static func columnOffsets(snapshot: TerminalSnapshot, row: Int) -> [Int] {
        guard snapshot.rows.indices.contains(row) else { return [] }
        var offsets: [Int] = []
        var utf16 = 0
        for cell in snapshot.rows[row] {
            offsets.append(utf16)
            guard cell.span != .continuation else { continue }
            utf16 += cell.text.isEmpty ? 1 : cell.text.utf16.count
        }
        offsets.append(utf16)
        return offsets
    }

    private static func offset(
        forColumn column: Int, in table: [[Int]], row: Int, lineLength: Int
    ) -> Int {
        guard table.indices.contains(row) else { return min(column, lineLength) }
        let offsets = table[row]
        guard !offsets.isEmpty else { return min(column, lineLength) }
        let index = min(max(column, 0), offsets.count - 1)
        return min(offsets[index], lineLength)
    }

    init(snapshot: TerminalSnapshot) {
        var joined = ""
        var ranges: [NSRange] = []
        var columnOffsets: [[Int]] = []
        ranges.reserveCapacity(snapshot.geometry.rows)
        columnOffsets.reserveCapacity(snapshot.geometry.rows)
        for row in 0 ..< snapshot.geometry.rows {
            let line = snapshot.plainText(row: row)
            ranges.append(NSRange(location: joined.utf16.count, length: line.utf16.count))
            columnOffsets.append(Self.columnOffsets(snapshot: snapshot, row: row))
            joined += line
            if row < snapshot.geometry.rows - 1 { joined += "\n" }
        }
        text = joined
        lineRanges = ranges
        self.columnOffsets = columnOffsets

        let cursorRow = min(max(snapshot.cursor.row, 0), max(0, ranges.count - 1))
        cursorLine = cursorRow
        if ranges.indices.contains(cursorRow) {
            let line = ranges[cursorRow]
            let offset = Self.offset(
                forColumn: snapshot.cursor.column, in: columnOffsets, row: cursorRow,
                lineLength: line.length)
            cursorRange = NSRange(location: line.location + offset, length: 0)
        } else {
            cursorRange = NSRange(location: 0, length: 0)
        }

        // A selection is stored against line identities, so it is mapped back
        // through the rows currently on screen rather than assumed contiguous.
        guard let selection = snapshot.selection,
            let startRow = snapshot.rowIDs.firstIndex(of: selection.start.line),
            let endRow = snapshot.rowIDs.firstIndex(of: selection.end.line),
            ranges.indices.contains(startRow), ranges.indices.contains(endRow)
        else {
            selectedRange = nil
            return
        }
        let startOffset =
            ranges[startRow].location
            + Self.offset(
                forColumn: selection.start.graphemeOffset, in: columnOffsets, row: startRow,
                lineLength: ranges[startRow].length)
        let endOffset =
            ranges[endRow].location
            + Self.offset(
                forColumn: selection.end.graphemeOffset, in: columnOffsets, row: endRow,
                lineLength: ranges[endRow].length)
        selectedRange = NSRange(
            location: min(startOffset, endOffset), length: abs(endOffset - startOffset))
    }

    /// Which line a character offset falls on.
    func line(for characterIndex: Int) -> Int {
        for (index, range) in lineRanges.enumerated()
        where characterIndex >= range.location && characterIndex <= NSMaxRange(range) {
            return index
        }
        return max(0, lineRanges.count - 1)
    }

    func range(forLine line: Int) -> NSRange {
        lineRanges.indices.contains(line) ? lineRanges[line] : NSRange(location: 0, length: 0)
    }

    func string(for range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
