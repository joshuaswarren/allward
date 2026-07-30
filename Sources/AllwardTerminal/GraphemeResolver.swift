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

    public func resolve(_ text: String) -> ResolvedGrapheme {
        let scalars = text.unicodeScalars
        guard let first = scalars.first else { return ResolvedGrapheme(text: text, width: 0) }
        let isEmojiCluster = scalars.contains { $0.value == 0xFE0F }
            || (scalars.contains { isEmojiPresentation($0.value) }
                && !scalars.contains { $0.value == 0xFE0E })
        let width = isEmojiCluster || isWide(first.value) ? 2 : 1
        return ResolvedGrapheme(text: text, width: width)
    }

    private func isEmojiPresentation(_ value: UInt32) -> Bool {
        (0x1F000...0x1FAFF).contains(value)
            || (0x2600...0x27BF).contains(value)
            || (0x2300...0x23FF).contains(value)
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
