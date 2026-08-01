import Foundation

// The literal token manifest for DESIGN-LANGUAGE §19-§20. Roles are normative;
// these literal values are the provisional v1 set pending the owner-approval
// assets in DL-OQ-01 and DL-OQ-02. They are versioned so a drift check can pin
// them, and they satisfy the ordering and contrast contracts today.

public enum TokenManifest {
    /// Bumped whenever any literal below changes. Receipts pin this value.
    public static let version = 1
}

// MARK: - Colour

/// A resolved sRGB colour. Kept free of AppKit so the manifest, its contrast
/// receipts, and its tests build anywhere.
public struct TokenColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#rrggbb` or `#rrggbbaa`.
    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else {
            return nil
        }
        let hasAlpha = text.count == 8
        let shift = hasAlpha ? 8 : 0
        red = Double((value >> (16 + shift)) & 0xFF) / 255
        green = Double((value >> (8 + shift)) & 0xFF) / 255
        blue = Double((value >> shift) & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    public var hexString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio against an opaque background.
    public func contrastRatio(against background: TokenColor) -> Double {
        let a = composited(over: background).relativeLuminance
        let b = background.relativeLuminance
        let lighter = max(a, b), darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Source-over composite, so contrast receipts measure final pixels rather
    /// than token arithmetic (DESIGN-LANGUAGE §20.3).
    public func composited(over background: TokenColor) -> TokenColor {
        guard alpha < 1 else { return self }
        let inverse = 1 - alpha
        return TokenColor(
            red * alpha + background.red * inverse,
            green * alpha + background.green * inverse,
            blue * alpha + background.blue * inverse
        )
    }

    public func withAlpha(_ newAlpha: Double) -> TokenColor {
        TokenColor(red, green, blue, alpha: newAlpha)
    }

    /// Linear blend toward another colour. Used only by the theme compiler when
    /// deriving Room tint roles from one approved base tint.
    public func mixed(with other: TokenColor, amount: Double) -> TokenColor {
        let t = min(max(amount, 0), 1)
        return TokenColor(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }
}

/// The semantic colour roles of DESIGN-LANGUAGE §20.1.
public enum ColorToken: String, Codable, Hashable, Sendable, CaseIterable {
    case canvas = "color.canvas"
    case surface = "color.surface"
    case surfaceRaised = "color.surface.raised"
    case surfaceScrim = "color.surface.scrim"
    case textPrimary = "color.text.primary"
    case textSecondary = "color.text.secondary"
    case textDisabled = "color.text.disabled"
    case strokeDivider = "color.stroke.divider"
    case strokeKeyboardFocus = "color.stroke.keyboardFocus"
    case selectionNative = "color.selection.native"
    case statePermission = "color.state.permission"
    case stateNeedsInput = "color.state.needsInput"
    case stateError = "color.state.error"
    case stateStale = "color.state.stale"
    case stateRunning = "color.state.running"
    case stateFinished = "color.state.finished"
    case stateIdle = "color.state.idle"
}

/// The Room tint roles of DESIGN-LANGUAGE §20.2.
public enum TintToken: String, Codable, Hashable, Sendable, CaseIterable {
    case seam = "room.tint.seam"
    case wash = "room.tint.wash"
    case focus = "room.tint.focus"
    case board = "room.tint.board"
    case router = "room.tint.router"
    case ambient = "room.tint.ambient"
    case material = "room.tint.material"
}

public enum Appearance: String, Codable, Hashable, Sendable, CaseIterable {
    case light
    case dark
}

/// System accessibility settings that change token resolution.
public struct AccessibilitySettings: Hashable, Sendable, Codable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool
    /// The user has asked for meaning to be carried by more than hue.
    ///
    /// Room identity is the one place this app leans on colour alone, so the
    /// setting has to reach the code that draws it rather than being assumed
    /// satisfied.
    public var differentiateWithoutColor: Bool

    public init(
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        differentiateWithoutColor: Bool = false
    ) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    public static let standard = AccessibilitySettings()
}

// MARK: - Typography

/// The type roles of DESIGN-LANGUAGE §19.1, ordered by §19.2.
public enum TypeToken: String, Codable, Hashable, Sendable, CaseIterable {
    case gridBody = "type.grid.body"
    case gridBold = "type.grid.bold"
    case gridItalic = "type.grid.italic"
    case gridPresentation = "type.grid.presentation"
    case uiCaption = "type.ui.caption"
    case uiLabel = "type.ui.label"
    case uiBody = "type.ui.body"
    case uiHeading = "type.ui.heading"
    case uiTitle = "type.ui.title"
    case uiRoom = "type.ui.room"
    case uiData = "type.ui.data"
    case ambientSecondary = "type.ambient.secondary"
    case ambientPrimary = "type.ambient.primary"

    /// The semantic scale order that no component may violate.
    public static let scaleOrder: [TypeToken] = [
        .uiCaption, .uiLabel, .uiBody, .uiHeading, .uiTitle, .uiRoom, .ambientSecondary,
        .ambientPrimary,
    ]
}

public enum TypeFamily: String, Codable, Hashable, Sendable, CaseIterable {
    /// User-configurable terminal monospace.
    case grid
    /// System UI family for Allward-owned chrome.
    case ui
    /// System monospace with tabular numerals for data roles.
    case data
}

public enum TypeWeight: String, Codable, Hashable, Sendable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold
}

public struct TypeStyle: Hashable, Sendable, Codable {
    public var family: TypeFamily
    public var size: Double
    public var weight: TypeWeight
    public var lineHeight: Double
    public var tracking: Double
    public var italic: Bool
    public var tabularNumerals: Bool

    public init(
        family: TypeFamily,
        size: Double,
        weight: TypeWeight = .regular,
        lineHeight: Double,
        tracking: Double = 0,
        italic: Bool = false,
        tabularNumerals: Bool = false
    ) {
        self.family = family
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.italic = italic
        self.tabularNumerals = tabularNumerals
    }

    public func scaled(by factor: Double) -> TypeStyle {
        var copy = self
        copy.size = (size * factor).rounded(.toNearestOrEven)
        copy.lineHeight = (lineHeight * factor).rounded(.toNearestOrEven)
        return copy
    }
}

/// The macOS Dynamic Type content-size categories Allward supports on native
/// chrome. Terminal rows and columns never change with these (§19.2).
public enum ContentSizeCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case small
    case medium
    case large
    case extraLarge
    case accessibilityMedium
    case accessibilityLarge

    public var scaleFactor: Double {
        switch self {
        case .small: 0.9
        case .medium: 1.0
        case .large: 1.12
        case .extraLarge: 1.25
        case .accessibilityMedium: 1.5
        case .accessibilityLarge: 1.8
        }
    }
}

// MARK: - Space, stroke, radius, material

public enum SpaceToken: String, Codable, Hashable, Sendable, CaseIterable {
    case inlineTight = "space.inline.tight"
    case inlineStandard = "space.inline.standard"
    case blockCompact = "space.block.compact"
    case blockStandard = "space.block.standard"
    case section = "space.section"

    public var points: Double {
        switch self {
        case .inlineTight: 4
        case .inlineStandard: 8
        case .blockCompact: 6
        case .blockStandard: 12
        case .section: 20
        }
    }
}

public enum RadiusToken: String, Codable, Hashable, Sendable, CaseIterable {
    case control = "radius.control"
    case panel = "radius.panel"
    case grid = "radius.grid"

    public var points: Double {
        switch self {
        case .control: 6
        case .panel: 12
        case .grid: 0
        }
    }
}

public enum StrokeToken: String, Codable, Hashable, Sendable, CaseIterable {
    case roomSeam = "stroke.roomSeam"
    case paneDivider = "stroke.paneDivider"
    case keyboardFocus = "stroke.keyboardFocus"

    public func width(_ settings: AccessibilitySettings) -> Double {
        switch self {
        case .roomSeam: 2
        case .paneDivider: 1
        case .keyboardFocus: settings.increaseContrast ? 3 : 2
        }
    }
}

public enum MaterialToken: String, Codable, Hashable, Sendable, CaseIterable {
    case gridOpaque = "material.grid.opaque"
    case chromeBase = "material.chrome.base"
    case chromeRaised = "material.chrome.raised"
    case chromeAlert = "material.chrome.alert"
}

/// How a material resolves once Reduce Transparency is applied (§20.5).
public enum MaterialResolution: Hashable, Sendable {
    case opaque(ColorToken)
    case blurred(ColorToken)

    public var baseColor: ColorToken {
        switch self {
        case .opaque(let token), .blurred(let token): token
        }
    }
}
