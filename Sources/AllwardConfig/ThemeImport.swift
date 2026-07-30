import Foundation
import AllwardCore
import AllwardDesign
import AllwardRooms

public struct ThemeImportResult: Sendable {
  public var theme: TerminalTheme
  public var unmappedFields: [String]

  public init(theme: TerminalTheme, unmappedFields: [String]) {
    self.theme = theme
    self.unmappedFields = unmappedFields
  }

  public var contrastIssues: [ThemeContrastIssue] {
    theme.contrastIssues()
  }
}

public enum ThemeImporter {
  public static func importITerm2(_ data: Data, name: String) throws -> ThemeImportResult {
    let object: Any
    do {
      object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      throw importError(key: "theme.iterm2", cause: "The property list is invalid: \(error.localizedDescription)")
    }
    guard let dictionary = object as? [String: Any] else {
      throw importError(key: "theme.iterm2", cause: "The property list root is not a dictionary")
    }
    var ansi: [TokenColor] = []
    for index in 0..<16 {
      ansi.append(try itermColor(dictionary["Ansi \(index) Color"], key: "Ansi \(index) Color"))
    }
    let foreground = try itermColor(dictionary["Foreground Color"], key: "Foreground Color")
    let background = try itermColor(dictionary["Background Color"], key: "Background Color")
    let cursor = try optionalITermColor(dictionary["Cursor Color"], key: "Cursor Color")
    let selection = try optionalITermColor(dictionary["Selection Color"], key: "Selection Color")
    let known = Set((0..<16).map { "Ansi \($0) Color" } + [
      "Foreground Color", "Background Color", "Cursor Color", "Selection Color",
    ])
    var unmapped = dictionary.keys.filter { !known.contains($0) }
    if cursor == nil { unmapped.append("cursor") }
    if selection == nil { unmapped.append("selection") }
    return ThemeImportResult(
      theme: TerminalTheme(
        name: name,
        ansi: Array(ansi[0..<8]),
        brights: Array(ansi[8..<16]),
        foreground: foreground,
        background: background,
        cursor: cursor,
        selection: selection
      ),
      unmappedFields: unmapped.sorted()
    )
  }

  public static func importGhostty(_ source: String, name: String) throws -> ThemeImportResult {
    var palette: [Int: TokenColor] = [:]
    var fields: [String: TokenColor] = [:]
    var unmapped: [String] = []
    for (lineNumber, rawLine) in source.split(whereSeparator: \Character.isNewline).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let equals = line.firstIndex(of: "=") else {
        unmapped.append("line.\(lineNumber + 1)")
        continue
      }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      let value = rawValue.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
      if key == "palette" {
        guard let paletteEquals = value.firstIndex(of: "=") else {
          throw importError(key: "theme.ghostty.palette", cause: "Palette entry is missing its index")
        }
        let indexText = value[..<paletteEquals]
        let colorText = value[value.index(after: paletteEquals)...]
        guard let index = Int(indexText),
              (0..<16).contains(index),
              let color = TokenColor(hex: String(colorText)) else {
          throw importError(key: "theme.ghostty.palette", cause: "Palette entry \(value) is invalid")
        }
        palette[index] = color
      } else if ["background", "foreground", "cursor-color", "selection-background"].contains(key) {
        guard let color = TokenColor(hex: value) else {
          throw importError(key: "theme.ghostty.\(key)", cause: "Colour \(value) is invalid")
        }
        fields[key] = color
      } else {
        unmapped.append(key)
      }
    }
    let colors = try (0..<16).map { index -> TokenColor in
      guard let color = palette[index] else {
        throw importError(key: "theme.ghostty.palette.\(index)", cause: "Palette entry \(index) is missing")
      }
      return color
    }
    guard let foreground = fields["foreground"] else {
      throw importError(key: "theme.ghostty.foreground", cause: "Foreground is missing")
    }
    guard let background = fields["background"] else {
      throw importError(key: "theme.ghostty.background", cause: "Background is missing")
    }
    if fields["cursor-color"] == nil { unmapped.append("cursor") }
    if fields["selection-background"] == nil { unmapped.append("selection") }
    return ThemeImportResult(
      theme: TerminalTheme(
        name: name,
        ansi: Array(colors[0..<8]),
        brights: Array(colors[8..<16]),
        foreground: foreground,
        background: background,
        cursor: fields["cursor-color"],
        selection: fields["selection-background"]
      ),
      unmappedFields: unmapped.sorted()
    )
  }

  public static func importBase16YAML(_ source: String, name: String? = nil) throws -> ThemeImportResult {
    var values: [String: String] = [:]
    var unmapped: [String] = []
    for (lineNumber, rawLine) in source.split(whereSeparator: \Character.isNewline).enumerated() {
      let line = stripYAMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, line != "---", line != "..." else { continue }
      guard let colon = line.firstIndex(of: ":") else {
        unmapped.append("line.\(lineNumber + 1)")
        continue
      }
      let rawKey = line[..<colon].trimmingCharacters(in: .whitespaces)
      let key = rawKey.lowercased().hasPrefix("base")
        ? "base" + rawKey.dropFirst(4).uppercased()
        : rawKey.lowercased()
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
         (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
        value.removeFirst()
        value.removeLast()
      }
      values[key] = value
    }
    let supportedPaletteKeys = Set((0...23).map { String(format: "base%02X", $0) })
    let knownMetadata: Set<String> = ["scheme", "name", "author", "variant", "slug"]
    unmapped += values.keys.filter { !supportedPaletteKeys.contains($0) && !knownMetadata.contains($0) }
    let palette = try values.reduce(into: [String: TokenColor]()) { result, entry in
      guard supportedPaletteKeys.contains(entry.key) else { return }
      guard let color = TokenColor(hex: entry.value.hasPrefix("#") ? entry.value : "#\(entry.value)") else {
        throw importError(key: "theme.yaml.\(entry.key)", cause: "Colour \(entry.value) is invalid")
      }
      result[entry.key] = color
    }
    let required = (0..<16).map { String(format: "base%02X", $0) }
    for key in required where palette[key] == nil {
      throw importError(key: "theme.yaml.\(key)", cause: "Required base16 colour is missing")
    }
    let ansiKeys = ["base00", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base05"]
    let brightKeys: [String]
    if (0x12...0x17).allSatisfy({ palette[String(format: "base%02X", $0)] != nil }) {
      brightKeys = ["base03", "base12", "base14", "base13", "base16", "base17", "base15", "base07"]
    } else {
      brightKeys = ["base03", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base07"]
    }
    return ThemeImportResult(
      theme: TerminalTheme(
        name: name ?? values["scheme"] ?? values["name"] ?? "Imported base16",
        ansi: ansiKeys.map { palette[$0]! },
        brights: brightKeys.map { palette[$0]! },
        foreground: palette["base05"]!,
        background: palette["base00"]!,
        cursor: nil,
        selection: nil
      ),
      unmappedFields: Array(Set(unmapped + ["cursor", "selection"])).sorted()
    )
  }

  private static func itermColor(_ value: Any?, key: String) throws -> TokenColor {
    guard let dictionary = value as? [String: Any],
          let red = number(dictionary["Red Component"]),
          let green = number(dictionary["Green Component"]),
          let blue = number(dictionary["Blue Component"]) else {
      throw importError(key: "theme.iterm2.\(key)", cause: "Colour components are missing")
    }
    let alpha = number(dictionary["Alpha Component"]) ?? 1
    guard (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue),
          (0...1).contains(alpha) else {
      throw importError(key: "theme.iterm2.\(key)", cause: "Colour components must be between zero and one")
    }
    return TokenColor(red, green, blue, alpha: alpha)
  }

  private static func optionalITermColor(_ value: Any?, key: String) throws -> TokenColor? {
    guard value != nil else { return nil }
    return try itermColor(value, key: key)
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  private static func stripYAMLComment(_ line: String) -> String {
    var quote: Character?
    for index in line.indices {
      let character = line[index]
      if character == "\"" || character == "'" {
        quote = quote == character ? nil : (quote == nil ? character : quote)
      } else if character == "#", quote == nil {
        return String(line[..<index])
      }
    }
    return line
  }

  private static func importError(key: String, cause: String) -> AllwardError {
    AllwardError(domain: .config, operation: key, cause: cause, recovery: "Correct or replace the imported theme")
  }
}
