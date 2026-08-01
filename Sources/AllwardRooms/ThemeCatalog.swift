import Foundation
import AllwardDesign

public struct ThemeContrastIssue: Codable, Hashable, Sendable {
  public var field: String
  public var ratio: Double
  public var requiredRatio: Double

  public init(field: String, ratio: Double, requiredRatio: Double) {
    self.field = field
    self.ratio = ratio
    self.requiredRatio = requiredRatio
  }
}

public struct TerminalTheme: Codable, Hashable, Sendable, Identifiable {
  public var name: String
  public var ansi: [TokenColor]
  public var brights: [TokenColor]
  public var foreground: TokenColor
  public var background: TokenColor
  public var cursor: TokenColor?
  public var selection: TokenColor?

  public var id: String { name }

  public init(
    name: String,
    ansi: [TokenColor],
    brights: [TokenColor],
    foreground: TokenColor,
    background: TokenColor,
    cursor: TokenColor?,
    selection: TokenColor?
  ) {
    precondition(ansi.count == 8, "A terminal theme requires eight ANSI colours")
    precondition(brights.count == 8, "A terminal theme requires eight bright ANSI colours")
    self.name = name
    self.ansi = ansi
    self.brights = brights
    self.foreground = foreground
    self.background = background
    self.cursor = cursor
    self.selection = selection
  }

  /// Palette slots that carry text.
  ///
  /// 0, 7 and 15 are the poles of the greyscale pair: on a dark theme the black
  /// end is a background and on a light theme the white end is, so holding them
  /// to a text floor would demand a palette that cannot exist. Everything else,
  /// including bright black — the colour shells use for comments and dim text —
  /// is read as text and has to be legible.
  static let textCarryingANSISlots: [Int] = Array(1 ... 6) + Array(8 ... 14)

  public func contrastIssues() -> [ThemeContrastIssue] {
    var issues: [ThemeContrastIssue] = []
    appendIssue(field: "foreground", color: foreground, threshold: 4.5, to: &issues)
    let palette = ansi + brights
    for slot in Self.textCarryingANSISlots where palette.indices.contains(slot) {
      appendIssue(field: "ansi[\(slot)]", color: palette[slot], threshold: 4.5, to: &issues)
    }
    if let cursor {
      appendIssue(field: "cursor", color: cursor, threshold: 3, to: &issues)
    }
    if let selection {
      appendIssue(field: "selection", color: selection, threshold: 3, to: &issues)
    }
    return issues
  }

  private func appendIssue(
    field: String,
    color: TokenColor,
    threshold: Double,
    to issues: inout [ThemeContrastIssue]
  ) {
    let ratio = color.contrastRatio(against: background)
    guard ratio < threshold else { return }
    issues.append(ThemeContrastIssue(field: field, ratio: ratio, requiredRatio: threshold))
  }
}

public enum ThemeCatalog {
  public static let darkDefault = TerminalTheme(
    name: "Allward Night",
    ansi: colors(["#15191e", "#d66b6b", "#73b58c", "#d4a95d", "#6f9ed6", "#a98bd4", "#63b7bd", "#c8cdd4"]),
    brights: colors(["#777d86", "#ef8585", "#8dcea4", "#e7c277", "#8ab7ea", "#c2a4e7", "#7ed0d5", "#f1f3f5"]),
    foreground: color("#dce0e5"),
    background: color("#0f1216"),
    cursor: color("#d4a95d"),
    selection: color("#52749b")
  )

  public static let lightDefault = TerminalTheme(
    name: "Allward Paper",
    ansi: colors(["#25282d", "#a83d3d", "#327348", "#8a641c", "#2f649b", "#75529a", "#28757b", "#e6e3dd"]),
    brights: colors(["#666b73", "#bc4c4c", "#3c7d52", "#8f6924", "#3c74ab", "#8561a7", "#2e7a80", "#ffffff"]),
    foreground: color("#24272b"),
    background: color("#f7f5f0"),
    cursor: color("#2f649b"),
    selection: color("#517da8")
  )

  public static let highContrastDark = TerminalTheme(
    name: "Allward Contrast",
    ansi: colors(["#000000", "#ff6b6b", "#75e092", "#ffd166", "#70b7ff", "#d19cff", "#69e1e8", "#f1f1f1"]),
    brights: colors(["#767676", "#ff9494", "#9af0ae", "#ffe08e", "#9acbff", "#e3bcff", "#93f0f4", "#ffffff"]),
    foreground: color("#ffffff"),
    background: color("#000000"),
    cursor: color("#ffffff"),
    selection: color("#397fbd")
  )

  public static let warmDark = TerminalTheme(
    name: "Allward Ember",
    ansi: colors(["#211b18", "#d76f62", "#8daa6a", "#d6a45f", "#7796b8", "#ad7f9d", "#6fa8a0", "#c9bfb4"]),
    brights: colors(["#857c75", "#ed8979", "#a7c282", "#ebbf78", "#91adca", "#c79ab7", "#89c0b7", "#eee5dc"]),
    foreground: color("#dfd6cd"),
    background: color("#171310"),
    cursor: color("#d6a45f"),
    selection: color("#93634a")
  )

  public static let builtIns = [darkDefault, lightDefault, highContrastDark, warmDark]

  public static func theme(named name: String) -> TerminalTheme? {
    builtIns.first { $0.name == name }
  }

  private static func color(_ hex: String) -> TokenColor {
    guard let value = TokenColor(hex: hex) else {
      preconditionFailure("Built-in terminal theme contains invalid colour \(hex)")
    }
    return value
  }

  private static func colors(_ values: [String]) -> [TokenColor] {
    values.map(color)
  }
}
