import AllwardCore
import AllwardDesign
import AppKit
import SwiftUI

// The single crossing point between the platform-free token manifest and
// AppKit/SwiftUI. Components read tokens through here so nobody hand-mixes a
// colour or invents a local type step.

extension TokenColor {
    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
            alpha: CGFloat(alpha))
    }

    public var cgColor: CGColor { nsColor.cgColor }
    public var swiftUIColor: Color { Color(nsColor: nsColor) }
}

extension TypeStyle {
    /// Resolved AppKit font. The grid family is user-configurable; chrome uses
    /// the system faces so Allward inherits macOS text rendering behaviour.
    public func font(gridFamily: String?) -> NSFont {
        let weight: NSFont.Weight =
            switch self.weight {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        var font: NSFont
        switch family {
        case .grid:
            font =
                gridFamily.flatMap { NSFont(name: $0, size: CGFloat(size)) }
                ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight)
        case .data:
            font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight)
        case .ui:
            font = NSFont.systemFont(ofSize: CGFloat(size), weight: weight)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    public var swiftUIFont: Font {
        let design: Font.Design = family == .ui ? .default : .monospaced
        let weight: Font.Weight =
            switch self.weight {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        var font = Font.system(size: CGFloat(size), weight: weight, design: design)
        if italic { font = font.italic() }
        return font
    }
}

/// Read the live system accessibility settings. Chrome refreshes this when the
/// workspace posts its accessibility-change notification, never on a timer.
@MainActor
public enum SystemAccessibility {
    public static func current() -> AllwardDesign.AccessibilitySettings {
        let workspace = NSWorkspace.shared
        return AllwardDesign.AccessibilitySettings(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }

    public static func appearance(for view: NSView?) -> Appearance {
        let name = (view?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? .dark : .light
    }
}

/// SwiftUI environment access to the resolved palette so surfaces never build
/// their own.
private struct DesignPaletteKey: EnvironmentKey {
    static let defaultValue = DesignPalette(appearance: .dark)
}

extension EnvironmentValues {
    public var allwardPalette: DesignPalette {
        get { self[DesignPaletteKey.self] }
        set { self[DesignPaletteKey.self] = newValue }
    }
}

extension View {
    public func allwardPalette(_ palette: DesignPalette) -> some View {
        environment(\.allwardPalette, palette)
    }

    /// Applies a token colour as foreground.
    public func tokenForeground(_ token: ColorToken, _ palette: DesignPalette) -> some View {
        foregroundStyle(palette[token].swiftUIColor)
    }

    /// Applies a named type role.
    public func tokenFont(_ token: TypeToken, _ palette: DesignPalette) -> some View {
        font(palette.type(token).swiftUIFont)
    }
}

/// A keyboard-focus ring drawn from tokens rather than the default AppKit ring,
/// so Increase Contrast can thicken it (DESIGN-LANGUAGE §20.6).
public struct KeyboardFocusRing: ViewModifier {
    public let isFocused: Bool
    public let palette: DesignPalette
    public let radius: RadiusToken

    public init(isFocused: Bool, palette: DesignPalette, radius: RadiusToken = .control) {
        self.isFocused = isFocused
        self.palette = palette
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius.points, style: .continuous)
                    .strokeBorder(
                        palette[.strokeKeyboardFocus].swiftUIColor,
                        lineWidth: StrokeToken.keyboardFocus.width(palette.settings))
            }
        }
    }
}
