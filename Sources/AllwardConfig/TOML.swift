import Foundation
import AllwardCore

public indirect enum TOMLValue: Hashable, Sendable {
  case string(String)
  case integer(Int64)
  case float(Double)
  case boolean(Bool)
  case array([TOMLValue])
  case table([String: TOMLValue])
}

private struct TOMLAssignment: Hashable, Sendable {
  let value: TOMLValue
  let range: Range<Int>
}

public struct TOMLDocument: Hashable, Sendable {
  public var root: [String: TOMLValue]
  private var originalSource: String?
  private var assignments: [String: TOMLAssignment]

  public init(root: [String: TOMLValue] = [:]) {
    self.root = root
    originalSource = nil
    assignments = [:]
  }

  fileprivate init(
    root: [String: TOMLValue],
    originalSource: String,
    assignments: [String: TOMLAssignment]
  ) {
    self.root = root
    self.originalSource = originalSource
    self.assignments = assignments
  }

  public static func parse(_ source: String) throws -> TOMLDocument {
    var parser = TOMLParser(source: source)
    return try parser.parse()
  }

  public func value(at path: [String]) -> TOMLValue? {
    var current: TOMLValue = .table(root)
    for component in path {
      guard case let .table(table) = current, let next = table[component] else { return nil }
      current = next
    }
    return current
  }

  public static func == (lhs: TOMLDocument, rhs: TOMLDocument) -> Bool {
    lhs.root == rhs.root
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(root)
  }

  public func serialized() -> String {
    var lines: [String] = []
    TOMLWriter.writeTable(root, path: [], includeHeader: false, into: &lines)
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
  }

  func serialized(updatingWith updated: TOMLDocument) -> String {
    guard let originalSource else { return updated.serialized() }
    let desiredValues = Self.flatten(updated.root)
    var characters = Array(originalSource)
    let replacements = assignments.compactMap { path, assignment -> (Range<Int>, String)? in
      guard let desired = desiredValues[path], desired != assignment.value else { return nil }
      return (assignment.range, TOMLWriter.render(desired))
    }.sorted { $0.0.lowerBound > $1.0.lowerBound }
    for (range, replacement) in replacements {
      characters.replaceSubrange(range, with: replacement)
    }
    return String(characters)
  }

  private static func flatten(_ root: [String: TOMLValue]) -> [String: TOMLValue] {
    var result: [String: TOMLValue] = [:]
    flattenTable(root, path: [], into: &result)
    return result
  }

  private static func flattenTable(
    _ table: [String: TOMLValue],
    path: [String],
    into result: inout [String: TOMLValue]
  ) {
    for (key, value) in table {
      switch value {
      case let .table(child):
        flattenTable(child, path: path + [key], into: &result)
      case let .array(values) where !values.isEmpty && values.allSatisfy({
        if case .table = $0 { true } else { false }
      }):
        for (index, value) in values.enumerated() {
          guard case let .table(child) = value else { continue }
          flattenTable(child, path: path + ["\(key)[\(index)]"], into: &result)
        }
      default:
        result[(path + [key]).joined(separator: ".")] = value
      }
    }
  }
}

private indirect enum ParsedValue {
  case scalar(TOMLValue)
  case array([ParsedValue])
  case table(ParsedTable)

  var publicValue: TOMLValue {
    switch self {
    case let .scalar(value): value
    case let .array(values): .array(values.map(\.publicValue))
    case let .table(table): .table(table.values.mapValues(\.publicValue))
    }
  }
}

private final class ParsedTable {
  var values: [String: ParsedValue] = [:]
  var explicitlyDeclared = false
  let concretePath: [String]

  init(concretePath: [String]) {
    self.concretePath = concretePath
  }
}

private struct TOMLParser {
  private let source: String
  private let characters: [Character]
  private var index = 0
  private var line = 1
  private let root: ParsedTable
  private var current: ParsedTable
  private var assignments: [String: TOMLAssignment] = [:]

  init(source: String) {
    self.source = source
    characters = Array(source)
    let root = ParsedTable(concretePath: [])
    self.root = root
    current = root
  }

  mutating func parse() throws -> TOMLDocument {
    while true {
      skipLayout()
      guard peek() != nil else { break }
      if peek() == "[" {
        try parseHeader()
      } else {
        try parseAssignment()
      }
      try finishStatement()
    }
    return TOMLDocument(
      root: root.values.mapValues(\.publicValue),
      originalSource: source,
      assignments: assignments
    )
  }

  private mutating func parseHeader() throws {
    try expect("[")
    let isArray = consume("[")
    let path = try parseKeyPath(terminator: "]")
    guard !path.isEmpty else { throw error("Table name is empty") }
    try expect("]")
    if isArray { try expect("]") }
    if isArray {
      current = try appendArrayTable(path)
    } else {
      let table = try resolveTable(path)
      guard !table.explicitlyDeclared else {
        throw error("Table \(path.joined(separator: ".")) is already declared")
      }
      table.explicitlyDeclared = true
      current = table
    }
  }

  private mutating func parseAssignment() throws {
    let path = try parseKeyPath(terminator: "=")
    guard !path.isEmpty else { throw error("Key is empty") }
    try expect("=")
    skipHorizontalWhitespace()
    let valueStart = index
    let value = try parseValue()
    let valueEnd = index
    let parent = try resolveTable(Array(path.dropLast()), startingAt: current)
    let key = path[path.count - 1]
    guard parent.values[key] == nil else { throw error("Duplicate key \(path.joined(separator: "."))") }
    parent.values[key] = value
    let concretePath = (parent.concretePath + [key]).joined(separator: ".")
    assignments[concretePath] = TOMLAssignment(
      value: value.publicValue,
      range: valueStart..<valueEnd
    )
  }

  private mutating func parseValue() throws -> ParsedValue {
    guard let character = peek() else { throw error("Missing value") }
    if character == "\"" { return .scalar(.string(try parseBasicString())) }
    if character == "'" { return .scalar(.string(try parseLiteralString())) }
    if character == "[" { return try parseArray() }
    let token = parseBareValue()
    if token == "true" { return .scalar(.boolean(true)) }
    if token == "false" { return .scalar(.boolean(false)) }
    let normalized = token.replacingOccurrences(of: "_", with: "")
    if !normalized.contains(".") && !normalized.lowercased().contains("e"), let integer = Int64(normalized) {
      return .scalar(.integer(integer))
    }
    if let float = Double(normalized) { return .scalar(.float(float)) }
    throw error("Unsupported value \(token)")
  }

  private mutating func parseArray() throws -> ParsedValue {
    try expect("[")
    var values: [ParsedValue] = []
    while true {
      skipArrayLayout()
      if consume("]") { return .array(values) }
      values.append(try parseValue())
      skipArrayLayout()
      if consume("]") { return .array(values) }
      try expect(",")
    }
  }

  private mutating func parseBasicString() throws -> String {
    try expect("\"")
    if consume("\"") {
      guard consume("\"") else { return "" }
      return try parseMultilineBasicString()
    }
    var result = ""
    while let character = advance() {
      if character == "\"" { return result }
      if character == "\n" || character == "\r" { throw error("Basic string cannot contain a newline") }
      if character == "\\" {
        result.append(try parseEscape(multiline: false))
      } else {
        result.append(character)
      }
    }
    throw error("Unterminated basic string")
  }

  private mutating func parseMultilineBasicString() throws -> String {
    if consume("\r") { _ = consume("\n") } else { _ = consume("\n") }
    var result = ""
    while peek() != nil {
      if peek() == "\"", peek(1) == "\"", peek(2) == "\"" {
        index += 3
        return result
      }
      guard let character = advance() else { break }
      if character == "\\" {
        if peek() == "\n" || peek() == "\r" {
          consumeNewline()
          skipArrayLayout()
        } else {
          result.append(try parseEscape(multiline: true))
        }
      } else {
        result.append(character)
      }
    }
    throw error("Unterminated multiline basic string")
  }

  private mutating func parseLiteralString() throws -> String {
    try expect("'")
    var result = ""
    while let character = advance() {
      if character == "'" { return result }
      if character == "\n" || character == "\r" { throw error("Literal string cannot contain a newline") }
      result.append(character)
    }
    throw error("Unterminated literal string")
  }

  private mutating func parseEscape(multiline: Bool) throws -> Character {
    guard let escaped = advance() else { throw error("Unterminated escape") }
    switch escaped {
    case "b": return "\u{8}"
    case "t": return "\t"
    case "n": return "\n"
    case "f": return "\u{c}"
    case "r": return "\r"
    case "\"": return "\""
    case "\\": return "\\"
    case "u": return try parseUnicodeEscape(length: 4)
    case "U": return try parseUnicodeEscape(length: 8)
    default:
      throw error("Invalid\(multiline ? " multiline" : "") escape \\(escaped)")
    }
  }

  private mutating func parseUnicodeEscape(length: Int) throws -> Character {
    var text = ""
    for _ in 0..<length {
      guard let character = advance(), character.isHexDigit else { throw error("Invalid Unicode escape") }
      text.append(character)
    }
    guard let value = UInt32(text, radix: 16), let scalar = UnicodeScalar(value) else {
      throw error("Invalid Unicode scalar")
    }
    return Character(scalar)
  }

  private mutating func parseBareValue() -> String {
    var token = ""
    while let character = peek(), !character.isWhitespace, character != ",", character != "]", character != "#" {
      token.append(advance()!)
    }
    return token
  }

  private mutating func parseKeyPath(terminator: Character) throws -> [String] {
    var components: [String] = []
    while true {
      skipHorizontalWhitespace()
      guard let character = peek(), character != terminator else { break }
      let component: String
      if character == "\"" {
        component = try parseBasicString()
      } else if character == "'" {
        component = try parseLiteralString()
      } else {
        var bare = ""
        while let next = peek(), !next.isWhitespace, next != ".", next != terminator {
          bare.append(advance()!)
        }
        component = bare
        guard bare.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }) else {
          throw error("Invalid bare key \(bare)")
        }
      }
      guard !component.isEmpty else { throw error("Empty dotted key component") }
      components.append(component)
      skipHorizontalWhitespace()
      guard consume(".") else { break }
    }
    return components
  }

  private mutating func resolveTable(_ path: [String], startingAt start: ParsedTable? = nil) throws -> ParsedTable {
    var table = start ?? root
    for component in path {
      if let existing = table.values[component] {
        switch existing {
        case let .table(next):
          table = next
        case let .array(values):
          guard case let .table(next)? = values.last else {
            throw error("\(component) is not a table")
          }
          table = next
        case .scalar:
          throw error("\(component) is not a table")
        }
      } else {
        let next = ParsedTable(concretePath: table.concretePath + [component])
        table.values[component] = .table(next)
        table = next
      }
    }
    return table
  }

  private mutating func appendArrayTable(_ path: [String]) throws -> ParsedTable {
    let parent = try resolveTable(Array(path.dropLast()))
    let key = path[path.count - 1]
    let existingCount: Int
    if case let .array(values)? = parent.values[key] {
      existingCount = values.count
    } else {
      existingCount = 0
    }
    let table = ParsedTable(concretePath: parent.concretePath + ["\(key)[\(existingCount)]"])
    table.explicitlyDeclared = true
    if let existing = parent.values[key] {
      guard case let .array(values) = existing,
            values.allSatisfy({ if case .table = $0 { true } else { false } }) else {
        throw error("\(key) is not an array of tables")
      }
      parent.values[key] = .array(values + [.table(table)])
    } else {
      parent.values[key] = .array([.table(table)])
    }
    return table
  }

  private mutating func finishStatement() throws {
    skipHorizontalWhitespace()
    if consume("#") {
      while let character = peek(), character != "\n", character != "\r" { _ = advance() }
    }
    guard peek() == nil || peek() == "\n" || peek() == "\r" else {
      throw error("Unexpected content after statement")
    }
    consumeNewline()
  }

  private mutating func skipLayout() {
    while true {
      skipHorizontalWhitespace()
      if consume("#") {
        while let character = peek(), character != "\n", character != "\r" { _ = advance() }
      }
      guard peek() == "\n" || peek() == "\r" else { return }
      consumeNewline()
    }
  }

  private mutating func skipArrayLayout() {
    while true {
      skipHorizontalWhitespace()
      if consume("#") {
        while let character = peek(), character != "\n", character != "\r" { _ = advance() }
      }
      guard peek() == "\n" || peek() == "\r" else { return }
      consumeNewline()
    }
  }

  private mutating func skipHorizontalWhitespace() {
    while peek() == " " || peek() == "\t" { index += 1 }
  }

  private mutating func consumeNewline() {
    if consume("\r") { _ = consume("\n") } else { _ = consume("\n") }
  }

  private func peek(_ offset: Int = 0) -> Character? {
    let position = index + offset
    return characters.indices.contains(position) ? characters[position] : nil
  }

  @discardableResult
  private mutating func advance() -> Character? {
    guard let character = peek() else { return nil }
    index += 1
    if character == "\n" { line += 1 }
    return character
  }

  private mutating func consume(_ expected: Character) -> Bool {
    guard peek() == expected else { return false }
    _ = advance()
    return true
  }

  private mutating func expect(_ expected: Character) throws {
    guard consume(expected) else { throw error("Expected \(expected)") }
  }

  private func error(_ cause: String) -> AllwardError {
    AllwardError(
      domain: .config,
      operation: "toml.line.\(line)",
      cause: cause,
      recovery: "Correct the TOML syntax at line \(line)"
    )
  }
}

private enum TOMLWriter {
  static func writeTable(
    _ table: [String: TOMLValue],
    path: [String],
    includeHeader: Bool,
    into lines: inout [String]
  ) {
    if includeHeader {
      if !lines.isEmpty && lines.last != "" { lines.append("") }
      lines.append("[\(path.map(renderKey).joined(separator: "."))]")
    }
    let keys = table.keys.sorted()
    for key in keys where isInline(table[key]!) {
      lines.append("\(renderKey(key)) = \(render(table[key]!))")
    }
    for key in keys {
      guard case let .table(child)? = table[key] else { continue }
      writeTable(child, path: path + [key], includeHeader: true, into: &lines)
    }
    for key in keys {
      guard case let .array(values)? = table[key], isArrayOfTables(values) else { continue }
      for value in values {
        guard case let .table(child) = value else { continue }
        if !lines.isEmpty && lines.last != "" { lines.append("") }
        lines.append("[[\((path + [key]).map(renderKey).joined(separator: "."))]]")
        writeArrayTableBody(child, path: path + [key], into: &lines)
      }
    }
  }

  private static func writeArrayTableBody(
    _ table: [String: TOMLValue],
    path: [String],
    into lines: inout [String]
  ) {
    let keys = table.keys.sorted()
    for key in keys where isInline(table[key]!) {
      lines.append("\(renderKey(key)) = \(render(table[key]!))")
    }
    for key in keys {
      guard case let .table(child)? = table[key] else { continue }
      writeTable(child, path: path + [key], includeHeader: true, into: &lines)
    }
    for key in keys {
      guard case let .array(values)? = table[key], isArrayOfTables(values) else { continue }
      for value in values {
        guard case let .table(child) = value else { continue }
        if lines.last != "" { lines.append("") }
        lines.append("[[\((path + [key]).map(renderKey).joined(separator: "."))]]")
        writeArrayTableBody(child, path: path + [key], into: &lines)
      }
    }
  }

  private static func isInline(_ value: TOMLValue) -> Bool {
    switch value {
    case .table: false
    case let .array(values): !isArrayOfTables(values)
    default: true
    }
  }

  private static func isArrayOfTables(_ values: [TOMLValue]) -> Bool {
    !values.isEmpty && values.allSatisfy(isTable)
  }

  private static func isTable(_ value: TOMLValue) -> Bool {
    if case .table = value { return true }
    return false
  }

  fileprivate static func render(_ value: TOMLValue) -> String {
    switch value {
    case let .string(string): renderString(string)
    case let .integer(integer): String(integer)
    case let .float(float):
      float.isFinite ? String(float) : (float.isNaN ? "nan" : (float.sign == .minus ? "-inf" : "inf"))
    case let .boolean(boolean): boolean ? "true" : "false"
    case let .array(values): "[\(values.map(render).joined(separator: ", "))]"
    case .table: preconditionFailure("Tables cannot be rendered inline")
    }
  }

  private static func renderString(_ value: String) -> String {
    if value.contains("\n") {
      let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
      return "\"\"\"\n\(escaped)\"\"\""
    }
    let escaped = value.reduce(into: "") { result, character in
      switch character {
      case "\\": result += "\\\\"
      case "\"": result += "\\\""
      case "\t": result += "\\t"
      case "\r": result += "\\r"
      default: result.append(character)
      }
    }
    return "\"\(escaped)\""
  }

  private static func renderKey(_ key: String) -> String {
    guard !key.isEmpty,
          key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
      return renderString(key)
    }
    return key
  }
}
