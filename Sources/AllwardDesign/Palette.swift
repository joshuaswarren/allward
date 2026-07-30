import Foundation

/// The resolved token set for one appearance, one accessibility configuration,
/// and one Room tint. Components read this; they never mix their own colours.
public struct DesignPalette: Hashable, Sendable {
    public let appearance: Appearance
    public let settings: AccessibilitySettings
    public let contentSize: ContentSizeCategory
    private let colors: [ColorToken: TokenColor]
    private let tints: [TintToken: TokenColor]

    public init(
        appearance: Appearance,
        settings: AccessibilitySettings = .standard,
        contentSize: ContentSizeCategory = .medium,
        roomTint: TokenColor? = nil
    ) {
        self.appearance = appearance
        self.settings = settings
        self.contentSize = contentSize
        self.colors = Self.resolveColors(appearance: appearance, settings: settings)
        let base = roomTint ?? Self.neutralTint(appearance)
        self.tints = Self.resolveTints(base: base, appearance: appearance, settings: settings)
    }

    public subscript(_ token: ColorToken) -> TokenColor {
        colors[token] ?? TokenColor(1, 0, 1)
    }

    public subscript(_ token: TintToken) -> TokenColor {
        tints[token] ?? TokenColor(1, 0, 1)
    }

    public func type(_ token: TypeToken) -> TypeStyle {
        TypeScale.style(token).scaled(by: token.isChrome ? contentSize.scaleFactor : 1)
    }

    /// The background a component composites onto, used by contrast receipts.
    public func background(for material: MaterialToken) -> TokenColor {
        self[resolve(material).baseColor]
    }

    public func resolve(_ material: MaterialToken) -> MaterialResolution {
        switch material {
        case .gridOpaque: .opaque(.canvas)
        case .chromeBase: settings.reduceTransparency ? .opaque(.surface) : .blurred(.surface)
        case .chromeRaised:
            settings.reduceTransparency ? .opaque(.surfaceRaised) : .blurred(.surfaceRaised)
        case .chromeAlert: .opaque(.surface)
        }
    }

    /// Room tint may influence chrome material only when Reduce Transparency is
    /// off; otherwise Room identity is the seam plus the name (§20.5).
    public var allowsTintedMaterial: Bool { !settings.reduceTransparency }

    // MARK: Literal manifest

    public static func neutralTint(_ appearance: Appearance) -> TokenColor {
        appearance == .dark ? TokenColor(hex: "#7d8794")! : TokenColor(hex: "#6b7280")!
    }

    private static func resolveColors(
        appearance: Appearance, settings: AccessibilitySettings
    ) -> [ColorToken: TokenColor] {
        let hc = settings.increaseContrast
        switch appearance {
        case .dark:
            return [
                .canvas: TokenColor(hex: hc ? "#000000" : "#0d1013")!,
                .surface: TokenColor(hex: hc ? "#0a0c0e" : "#16191d")!,
                .surfaceRaised: TokenColor(hex: hc ? "#131619" : "#1f2328")!,
                .surfaceScrim: TokenColor(hex: "#000000")!.withAlpha(hc ? 0.72 : 0.55),
                .textPrimary: TokenColor(hex: hc ? "#ffffff" : "#e8eaed")!,
                .textSecondary: TokenColor(hex: hc ? "#d6dae0" : "#a4acb8")!,
                .textDisabled: TokenColor(hex: hc ? "#a9b1bb" : "#8b93a1")!,
                .strokeDivider: TokenColor(hex: hc ? "#5a626d" : "#2c3138")!,
                .strokeKeyboardFocus: TokenColor(hex: hc ? "#ffffff" : "#7ab8ff")!,
                .selectionNative: TokenColor(hex: hc ? "#2f6db5" : "#274c77")!,
                .statePermission: TokenColor(hex: hc ? "#ffd479" : "#e5b567")!,
                .stateNeedsInput: TokenColor(hex: hc ? "#ffc46b" : "#eda44b")!,
                .stateError: TokenColor(hex: hc ? "#ff8f8a" : "#e8756e")!,
                .stateStale: TokenColor(hex: hc ? "#c3cad4" : "#9aa3b0")!,
                .stateRunning: TokenColor(hex: hc ? "#8fd4ff" : "#6cb6e8")!,
                .stateFinished: TokenColor(hex: hc ? "#8ce09b" : "#6cc47f")!,
                .stateIdle: TokenColor(hex: hc ? "#b9c1cc" : "#8b93a1")!,
            ]
        case .light:
            return [
                .canvas: TokenColor(hex: hc ? "#ffffff" : "#fbfbfa")!,
                .surface: TokenColor(hex: hc ? "#ffffff" : "#f2f2f0")!,
                .surfaceRaised: TokenColor(hex: "#ffffff")!,
                .surfaceScrim: TokenColor(hex: "#1b1d20")!.withAlpha(hc ? 0.5 : 0.32),
                .textPrimary: TokenColor(hex: hc ? "#000000" : "#1b1d20")!,
                .textSecondary: TokenColor(hex: hc ? "#33383f" : "#585f69")!,
                .textDisabled: TokenColor(hex: hc ? "#4a505a" : "#636a75")!,
                .strokeDivider: TokenColor(hex: hc ? "#9aa1ab" : "#d9dade")!,
                .strokeKeyboardFocus: TokenColor(hex: hc ? "#000000" : "#1b6fd0")!,
                .selectionNative: TokenColor(hex: hc ? "#a9c9ef" : "#cbdff5")!,
                .statePermission: TokenColor(hex: hc ? "#6b4a00" : "#8a6100")!,
                .stateNeedsInput: TokenColor(hex: hc ? "#6d4300" : "#8a5500")!,
                .stateError: TokenColor(hex: hc ? "#8a1109" : "#a3271e")!,
                .stateStale: TokenColor(hex: hc ? "#3f454d" : "#5f666f")!,
                .stateRunning: TokenColor(hex: hc ? "#0d4a75" : "#1a5f8f")!,
                .stateFinished: TokenColor(hex: hc ? "#0d5323" : "#1d6b33")!,
                .stateIdle: TokenColor(hex: hc ? "#464c55" : "#666d77")!,
            ]
        }
    }

    private static func resolveTints(
        base: TokenColor, appearance: Appearance, settings: AccessibilitySettings
    ) -> [TintToken: TokenColor] {
        let canvas = resolveColors(appearance: appearance, settings: settings)[.canvas]!
        let saturationBoost = settings.increaseContrast ? 0.15 : 0.0
        let seam = base.mixed(
            with: appearance == .dark ? TokenColor(1, 1, 1) : TokenColor(0, 0, 0),
            amount: saturationBoost)
        return [
            .seam: seam,
            .wash: seam.mixed(with: canvas, amount: settings.increaseContrast ? 0.78 : 0.88),
            .focus: seam.mixed(with: canvas, amount: 0.35),
            .board: seam.mixed(with: canvas, amount: 0.82),
            .router: seam.mixed(with: canvas, amount: 0.6),
            .ambient: seam,
            .material: seam.withAlpha(settings.reduceTransparency ? 0 : 0.1),
        ]
    }
}

extension TypeToken {
    /// Chrome roles follow Dynamic Type; grid roles never do (§19.2).
    public var isChrome: Bool {
        switch self {
        case .gridBody, .gridBold, .gridItalic, .gridPresentation: false
        default: true
        }
    }
}

/// The literal type scale. Ordering is asserted by tests, not by convention.
public enum TypeScale {
    public static func style(_ token: TypeToken) -> TypeStyle {
        switch token {
        case .gridBody: TypeStyle(family: .grid, size: 13, lineHeight: 17)
        case .gridBold: TypeStyle(family: .grid, size: 13, weight: .bold, lineHeight: 17)
        case .gridItalic: TypeStyle(family: .grid, size: 13, lineHeight: 17, italic: true)
        case .gridPresentation: TypeStyle(family: .grid, size: 18, lineHeight: 23)
        case .uiCaption: TypeStyle(family: .ui, size: 10, lineHeight: 13)
        case .uiLabel: TypeStyle(family: .ui, size: 11, weight: .medium, lineHeight: 14)
        case .uiBody: TypeStyle(family: .ui, size: 13, lineHeight: 18)
        case .uiHeading: TypeStyle(family: .ui, size: 14, weight: .semibold, lineHeight: 19)
        case .uiTitle: TypeStyle(family: .ui, size: 15, weight: .semibold, lineHeight: 20)
        case .uiRoom: TypeStyle(family: .ui, size: 16, weight: .semibold, lineHeight: 21)
        case .uiData:
            TypeStyle(family: .data, size: 11, lineHeight: 14, tabularNumerals: true)
        case .ambientSecondary: TypeStyle(family: .ui, size: 22, lineHeight: 28)
        case .ambientPrimary:
            TypeStyle(family: .ui, size: 34, weight: .semibold, lineHeight: 41)
        }
    }
}
