import Foundation

/// The colours a program can ask about, and the answers.
///
/// A TUI decides whether to paint light text or dark text by asking the
/// terminal what its background is (`OSC 11 ; ? ST`). Allward parsed that
/// question and dropped it, so nothing came back; the common library fallback
/// is to assume a light background and choose dark foregrounds, which on a dark
/// grid look black and all but invisible. Answering is not a nicety - it is how
/// a program knows what it is drawing on.
public struct DynamicColors: Hashable, Sendable {
    /// Slot numbers as defined by xterm: these are the OSC command numbers.
    public enum Slot: Int, Hashable, Sendable, CaseIterable {
        case foreground = 10
        case background = 11
        case cursor = 12
    }

    public struct RGB: Hashable, Sendable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// xterm reports 16 bits per channel, so an 8-bit value is repeated
        /// rather than padded - `ff` becomes `ffff`, not `ff00`.
        public var xtermDescription: String {
            String(
                format: "rgb:%02x%02x/%02x%02x/%02x%02x",
                red, red, green, green, blue, blue)
        }

        /// Parses the forms programs actually send: `#rgb`, `#rrggbb`,
        /// `rgb:r/g/b` with 1-4 hex digits per channel, and `rgbi:` ratios.
        public static func parse(_ text: String) -> RGB? {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("#") { return parseHash(String(value.dropFirst())) }
            if value.hasPrefix("rgb:") { return parseChannels(String(value.dropFirst(4))) }
            if value.hasPrefix("rgbi:") { return parseIntensities(String(value.dropFirst(5))) }
            return nil
        }

        private static func parseHash(_ digits: String) -> RGB? {
            let width = digits.count / 3
            guard width >= 1, width <= 4, digits.count == width * 3 else { return nil }
            let scalars = Array(digits)
            var channels: [UInt8] = []
            for index in 0 ..< 3 {
                let slice = String(scalars[(index * width) ..< ((index + 1) * width)])
                guard let scaled = scale(slice) else { return nil }
                channels.append(scaled)
            }
            return RGB(channels[0], channels[1], channels[2])
        }

        private static func parseChannels(_ body: String) -> RGB? {
            let parts = body.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var channels: [UInt8] = []
            for part in parts {
                guard let scaled = scale(String(part)) else { return nil }
                channels.append(scaled)
            }
            return RGB(channels[0], channels[1], channels[2])
        }

        private static func parseIntensities(_ body: String) -> RGB? {
            let parts = body.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var channels: [UInt8] = []
            for part in parts {
                guard let ratio = Double(part), ratio >= 0, ratio <= 1 else { return nil }
                channels.append(UInt8((ratio * 255).rounded()))
            }
            return RGB(channels[0], channels[1], channels[2])
        }

        /// Widens or narrows a hex channel of any width to 8 bits.
        private static func scale(_ digits: String) -> UInt8? {
            guard !digits.isEmpty, digits.count <= 4,
                let raw = UInt32(digits, radix: 16)
            else { return nil }
            let maximum = (UInt32(1) << (4 * digits.count)) - 1
            guard maximum > 0 else { return nil }
            return UInt8((Double(raw) / Double(maximum) * 255).rounded())
        }
    }

    /// What the theme currently paints with. The engine does not own the theme,
    /// so the application keeps these in step; queries are answered from here.
    public var defaults: [Slot: RGB]
    private var overrides: [Slot: RGB] = [:]

    public init(
        foreground: RGB = RGB(0xd7, 0xdc, 0xe3),
        background: RGB = RGB(0x0f, 0x12, 0x16),
        cursor: RGB = RGB(0xff, 0xc2, 0x33)
    ) {
        defaults = [.foreground: foreground, .background: background, .cursor: cursor]
    }

    public subscript(slot: Slot) -> RGB {
        overrides[slot] ?? defaults[slot] ?? RGB(0, 0, 0)
    }

    public mutating func set(_ slot: Slot, to color: RGB) { overrides[slot] = color }
    public mutating func reset(_ slot: Slot) { overrides.removeValue(forKey: slot) }
    public var hasOverrides: Bool { !overrides.isEmpty }

    /// The reply to a query, terminated the way the asker terminated its
    /// question - a program that sent BEL expects BEL back.
    public func reply(for slot: Slot, terminator: StringTerminator) -> [UInt8] {
        Array("\u{1B}]\(slot.rawValue);\(self[slot].xtermDescription)\(terminator.text)".utf8)
    }
}

/// How a string command was ended. Programs use both and expect the same back.
public enum StringTerminator: Hashable, Sendable {
    case bell
    case stringTerminator

    public var text: String {
        switch self {
        case .bell: "\u{07}"
        case .stringTerminator: "\u{1B}\\"
        }
    }
}
