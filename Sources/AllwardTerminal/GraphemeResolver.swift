import Foundation

public struct ResolvedGrapheme: Hashable, Sendable {
    public var text: String
    public var width: Int

    public init(text: String, width: Int) {
        self.text = text
        self.width = width
    }
}

public struct GraphemeResolver: Sendable {
    public init() {}

    public func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .nonspacingMark
            || scalar.properties.generalCategory == .spacingMark
            || scalar.properties.generalCategory == .enclosingMark
    }

    public func shouldAttach(_ scalar: Unicode.Scalar, to cluster: String) -> Bool {
        guard !cluster.isEmpty else { return false }
        return (cluster + String(scalar)).count == 1
    }

    /// How many columns a cluster occupies.
    ///
    /// Width is a contract, not a rendering detail: a program lays out a line
    /// by counting columns, and if the terminal disagrees the cursor ends up
    /// somewhere the program did not expect and its next write lands on top of
    /// what it just drew.
    ///
    /// That is what hid herdr's tick. Emoji presentation was three hand-written
    /// ranges, and `0x2600...0x27BF` swept in the entire Dingbats block, so
    /// `✓`, `✗` and `❯` were each declared two columns wide when every other
    /// terminal gives them one. herdr wrote the tick, moved on by one column,
    /// and the padding that followed overwrote it. The glyph was never missing;
    /// it was erased a microsecond after being drawn.
    public func resolve(_ text: String) -> ResolvedGrapheme {
        let scalars = text.unicodeScalars
        guard let first = scalars.first else { return ResolvedGrapheme(text: text, width: 0) }
        let requestsText = scalars.contains { $0.value == 0xFE0E }
        let requestsEmoji = scalars.contains { $0.value == 0xFE0F } && first.properties.isEmoji
        let defaultsToEmoji = scalars.contains { isEmojiPresentation($0) }
        let isEmojiCluster = !requestsText && (requestsEmoji || defaultsToEmoji)
        let width = isEmojiCluster || isWide(first.value) ? 2 : 1
        return ResolvedGrapheme(text: text, width: width)
    }

    /// Whether a character is drawn as an emoji when nothing says otherwise.
    /// Unicode publishes this as a character property, so it is asked rather
    /// than approximated with block ranges.
    private func isEmojiPresentation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation
    }

    private func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }
}
