import AllwardCore

/// One occurrence of a search string in a session's scrollback.
public struct SearchMatch: Hashable, Sendable {
    public let line: LineID
    public let column: Int
    public let length: Int
    /// The scroll offset that brings this match's line into the viewport.
    public let scrollOffset: Int

    public init(line: LineID, column: Int, length: Int, scrollOffset: Int) {
        self.line = line
        self.column = column
        self.length = length
        self.scrollOffset = scrollOffset
    }
}
