import AllwardDesign
import AllwardTerminal

public struct TerminalTheme: Hashable, Sendable {
    public let ansiColors: [TokenColor]
    public let defaultForeground: TokenColor
    public let defaultBackground: TokenColor
    public let cursor: TokenColor
    public let selectionBackground: TokenColor
    public let selectionForeground: TokenColor

    public init(
        ansiColors: [TokenColor],
        defaultForeground: TokenColor,
        defaultBackground: TokenColor,
        cursor: TokenColor,
        selectionBackground: TokenColor,
        selectionForeground: TokenColor
    ) {
        precondition(ansiColors.count == 16, "A terminal theme requires exactly 16 ANSI colours")
        self.ansiColors = ansiColors
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
    }

    public var normalANSIColors: ArraySlice<TokenColor> { ansiColors[0 ..< 8] }
    public var brightANSIColors: ArraySlice<TokenColor> { ansiColors[8 ..< 16] }

    public func resolve(_ color: TerminalColor) -> TokenColor {
        switch color {
        case .defaultForeground:
            defaultForeground
        case .defaultBackground:
            defaultBackground
        case let .rgb(red, green, blue):
            TokenColor(Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        case let .indexed(index):
            resolveIndexed(index)
        }
    }

    public static let builtInDark = TerminalTheme(
        ansiColors: [
            color("#171817"), color("#d36c67"), color("#7da277"), color("#c5a65a"),
            color("#7199bd"), color("#a98bb8"), color("#6da7a1"), color("#c8c2b8"),
            color("#5f625f"), color("#e4827c"), color("#92b98b"), color("#d8bb70"),
            color("#89afd0"), color("#bea0cb"), color("#82bdb7"), color("#eee8de"),
        ],
        defaultForeground: color("#ded8cf"),
        defaultBackground: color("#111312"),
        cursor: color("#ded8cf"),
        selectionBackground: color("#48545f"),
        selectionForeground: color("#f5f1ea")
    )

    public static let builtInLight = TerminalTheme(
        ansiColors: [
            color("#292a28"), color("#a5433f"), color("#487542"), color("#8b6e20"),
            color("#3d6f99"), color("#765487"), color("#397a74"), color("#d8d3ca"),
            color("#666965"), color("#bd5752"), color("#5b8b54"), color("#9b7d2e"),
            color("#4f82ad"), color("#88659a"), color("#4b8e87"), color("#f5f1e9"),
        ],
        defaultForeground: color("#2b2d2b"),
        defaultBackground: color("#f5f2eb"),
        cursor: color("#343735"),
        selectionBackground: color("#c4d4e2"),
        selectionForeground: color("#1e252b")
    )

    public static let `default` = builtInDark

    private func resolveIndexed(_ index: UInt8) -> TokenColor {
        let value = Int(index)
        if value < 16 {
            return ansiColors[value]
        }
        if value < 232 {
            let cubeIndex = value - 16
            let red = cubeIndex / 36
            let green = (cubeIndex / 6) % 6
            let blue = cubeIndex % 6
            return TokenColor(cubeChannel(red), cubeChannel(green), cubeChannel(blue))
        }
        let grey = Double(8 + (value - 232) * 10) / 255
        return TokenColor(grey, grey, grey)
    }

    private func cubeChannel(_ value: Int) -> Double {
        value == 0 ? 0 : Double(55 + value * 40) / 255
    }

    private static func color(_ hex: String) -> TokenColor {
        guard let color = TokenColor(hex: hex) else {
            preconditionFailure("Invalid built-in terminal colour")
        }
        return color
    }
}
