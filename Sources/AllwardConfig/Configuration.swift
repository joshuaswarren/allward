import Foundation
import Dispatch

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

import AllwardCore
import AllwardDesign
import AllwardRooms
#if canImport(AppKit)
import CoreText
#endif

public enum CursorShape: String, Codable, Hashable, Sendable, CaseIterable {
  case block
  case beam
  case underline
}

public enum BoardPresentation: String, Codable, Hashable, Sendable, CaseIterable {
  case compact
  case comfortable
  case ambient
}

public struct TerminalConfiguration: Codable, Hashable, Sendable {
  private static let preferredFontFamilies = [
    "MesloLGS NF",
    "JetBrainsMono Nerd Font",
    "Hack Nerd Font",
    "FiraCode Nerd Font",
    "SF Mono",
    "Menlo",
  ]

  public static let defaultFontFamily: String = {
#if canImport(AppKit)
    for family in preferredFontFamilies {
      let font = CTFontCreateWithName(family as CFString, 13, nil)
      guard CTFontCopyFamilyName(font) as String == family else { continue }
      return family
    }
#endif
    return "SF Mono"
  }()

  public var fontFamily: String
  public var fontSize: Double
  public var theme: String
  public var cursorShape: CursorShape
  public var cursorBlink: Bool
  public var scrollbackCapacity: Int
  /// Draw bold text in the bright half of the palette.
  public var boldIsBright: Bool
  /// WCAG contrast floor between text and its cell background. 1 disables it.
  public var minimumContrast: Double

  public init(
    fontFamily: String = TerminalConfiguration.defaultFontFamily,
    fontSize: Double = 13,
    theme: String = ThemeCatalog.darkDefault.name,
    cursorShape: CursorShape = .block,
    cursorBlink: Bool = false,
    scrollbackCapacity: Int = 100_000,
    boldIsBright: Bool = false,
    minimumContrast: Double = 1
  ) {
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.theme = theme
    self.cursorShape = cursorShape
    self.cursorBlink = cursorBlink
    self.scrollbackCapacity = scrollbackCapacity
    self.boldIsBright = boldIsBright
    self.minimumContrast = max(1, minimumContrast)
  }
}

public struct HostConfiguration: Codable, Hashable, Sendable {
  public var alias: HostAlias
  public var hostname: String
  public var user: String?
  public var port: Int

  public init(alias: HostAlias, hostname: String, user: String? = nil, port: Int = 22) {
    self.alias = alias
    self.hostname = hostname
    self.user = user
    self.port = port
  }
}

public struct Configuration: Hashable, Sendable {
  private struct SourceRevision: Hashable, Sendable {
    let path: String
    let data: Data
  }

  public var generation: Generation
  public var terminal: TerminalConfiguration
  public var rooms: [Room]
  public var hosts: [HostConfiguration]
  public var earconsEnabled: Bool
  public var boardPresentation: BoardPresentation
  public var dictationKey: String
  public var mcpEnabled: Bool
  private var sourceRevision: SourceRevision?
  private var sourceDocument: TOMLDocument?

  public init(
    generation: Generation = .initial,
    terminal: TerminalConfiguration = TerminalConfiguration(),
    rooms: [Room] = [.personal, .work],
    hosts: [HostConfiguration] = [],
    earconsEnabled: Bool = false,
    boardPresentation: BoardPresentation = .comfortable,
    dictationKey: String = "fn fn",
    mcpEnabled: Bool = false
  ) {
    self.generation = generation
    self.terminal = terminal
    self.rooms = rooms
    self.hosts = hosts
    self.earconsEnabled = earconsEnabled
    self.boardPresentation = boardPresentation
    self.dictationKey = dictationKey
    self.mcpEnabled = mcpEnabled
  }

  public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
    lhs.generation == rhs.generation
      && lhs.terminal == rhs.terminal
      && lhs.rooms == rhs.rooms
      && lhs.hosts == rhs.hosts
      && lhs.earconsEnabled == rhs.earconsEnabled
      && lhs.boardPresentation == rhs.boardPresentation
      && lhs.dictationKey == rhs.dictationKey
      && lhs.mcpEnabled == rhs.mcpEnabled
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(generation)
    hasher.combine(terminal)
    hasher.combine(rooms)
    hasher.combine(hosts)
    hasher.combine(earconsEnabled)
    hasher.combine(boardPresentation)
    hasher.combine(dictationKey)
    hasher.combine(mcpEnabled)
  }

  public static let `default` = Configuration()

  public static func load(from url: URL) throws -> Configuration {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw configError(key: "config.file", cause: "Unable to read config: \(error.localizedDescription)")
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw configError(key: "config.file", cause: "Config is not valid UTF-8")
    }
    let document = try TOMLDocument.parse(source)
    var configuration = try from(document: document)
    try configuration.validate()
    configuration.sourceRevision = SourceRevision(path: url.standardizedFileURL.path, data: data)
    configuration.sourceDocument = document
    return configuration
  }

  public func validate() throws {
    try require(!terminal.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                key: "terminal.font-family", cause: "Font family cannot be empty")
    try require(terminal.fontSize.isFinite && (6...72).contains(terminal.fontSize),
                key: "terminal.font-size", cause: "Font size must be between 6 and 72 points")
    try require(!terminal.theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                key: "terminal.theme", cause: "Theme name cannot be empty")
    try require((1...10_000_000).contains(terminal.scrollbackCapacity),
                key: "terminal.scrollback-capacity", cause: "Scrollback capacity must be between 1 and 10000000")
    try require(!rooms.isEmpty, key: "rooms", cause: "At least one Room is required")
    try require(Set(rooms.map(\.id)).count == rooms.count,
                key: "rooms.id", cause: "Room identifiers must be unique")
    try require(Set(rooms.map { $0.name.lowercased() }).count == rooms.count,
                key: "rooms.name", cause: "Room names must be unique")
    let aliases = hosts.map { $0.alias.rawValue }
    try require(Set(aliases).count == aliases.count,
                key: "hosts.alias", cause: "Host aliases must be unique")
    let configuredAliases = Set(hosts.map(\.alias))
    for (index, host) in hosts.enumerated() {
      try require(!host.alias.rawValue.isEmpty, key: "hosts[\(index)].alias", cause: "Host alias cannot be empty")
      try require(!host.hostname.isEmpty, key: "hosts[\(index)].hostname", cause: "Hostname cannot be empty")
      try require((1...65_535).contains(host.port), key: "hosts[\(index)].port", cause: "Port is out of range")
    }
    var mappedHosts: Set<HostAlias> = []
    var mappedAdapterServers: Set<AdapterServerReference> = []
    var mappedSessions: Set<SessionID> = []
    var mappedPanes: Set<PaneID> = []
    var mappedWorkspaces: Set<AdapterWorkspaceReference> = []
    for (index, room) in rooms.enumerated() {
      try require(!room.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  key: "rooms[\(index)].name", cause: "Room name cannot be empty")
      try require(!room.terminalThemeName.isEmpty,
                  key: "rooms[\(index)].terminal-theme", cause: "Room theme cannot be empty")
      let channels = [room.baseTint.red, room.baseTint.green, room.baseTint.blue, room.baseTint.alpha]
      try require(channels.allSatisfy { $0.isFinite && (0...1).contains($0) },
                  key: "rooms[\(index)].tint", cause: "Room tint channels must be between zero and one")
      for alias in room.hostAliases {
        try require(
          configuredAliases.contains(alias),
          key: "rooms[\(index)].host-aliases",
          cause: "Host alias \(alias.rawValue) is not configured"
        )
        guard mappedHosts.insert(alias).inserted else {
          throw Self.configError(
            key: "rooms[\(index)].host-aliases",
            cause: "Host alias \(alias.rawValue) is associated with more than one Room"
          )
        }
      }
      for adapterServer in room.adapterServers {
        guard mappedAdapterServers.insert(adapterServer).inserted else {
          throw Self.configError(
            key: "rooms[\(index)].adapter-servers",
            cause: "Adapter server is associated with more than one Room"
          )
        }
      }
      for session in room.sessionMappings {
        guard mappedSessions.insert(session).inserted else {
          throw Self.configError(
            key: "rooms[\(index)].session-mappings",
            cause: "Session is associated with more than one Room"
          )
        }
      }
      for pane in room.paneMappings {
        guard mappedPanes.insert(pane).inserted else {
          throw Self.configError(
            key: "rooms[\(index)].pane-mappings",
            cause: "Pane is associated with more than one Room"
          )
        }
      }
      for workspace in room.workspaceMappings {
        guard mappedWorkspaces.insert(workspace).inserted else {
          throw Self.configError(
            key: "rooms[\(index)].workspace-mappings",
            cause: "Workspace is associated with more than one Room"
          )
        }
      }
      if case let .host(alias) = room.defaults.destination {
        try require(configuredAliases.contains(alias),
                    key: "rooms[\(index)].default-destination", cause: "Host alias \(alias.rawValue) is not configured")
      }
      if let directory = room.defaults.workingDirectory {
        try require(!directory.isEmpty,
                    key: "rooms[\(index)].default-working-directory", cause: "Working directory cannot be empty")
      }
    }
    try require(!dictationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                key: "speech.dictation-key", cause: "Dictation key cannot be empty")
  }

  public func write(to url: URL) throws -> Configuration {
    try validate()
    let updatedDocument = document()
    var source = sourceDocument?.serialized(updatingWith: updatedDocument) ?? updatedDocument.serialized()
    var outputDocument = try TOMLDocument.parse(source)
    var decoded = try Configuration.from(document: outputDocument)
    var expected = self
    decoded.generation = .initial
    expected.generation = .initial
    if decoded != expected {
      source = updatedDocument.serialized()
      outputDocument = try TOMLDocument.parse(source)
      decoded = try Configuration.from(document: outputDocument)
    }
    try decoded.validate()
    let outputData = Data(source.utf8)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try outputData.write(to: temporaryURL, options: .withoutOverwriting)
      if let sourceRevision, sourceRevision.path == url.standardizedFileURL.path {
        let currentData: Data
        do {
          currentData = try Data(contentsOf: url)
        } catch {
          throw Self.configError(
            key: "config.generation",
            cause: "The loaded config file no longer exists or cannot be read"
          )
        }
        guard currentData == sourceRevision.data else {
          throw Self.configError(
            key: "config.generation",
            cause: "The config changed outside Allward after this generation loaded"
          )
        }
      }
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: url)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      if let allwardError = error as? AllwardError { throw allwardError }
      throw Self.configError(key: "config.file", cause: "Atomic write failed: \(error.localizedDescription)")
    }
    var written = self
    written.generation = generation.next
    written.sourceRevision = SourceRevision(path: url.standardizedFileURL.path, data: outputData)
    written.sourceDocument = outputDocument
    return written
  }

  private static func from(document: TOMLDocument) throws -> Configuration {
    let root = document.root
    let terminalTable = try table(root["terminal"], key: "terminal", default: [:])
    let terminal = TerminalConfiguration(
      fontFamily: try string(
        terminalTable["font-family"],
        key: "terminal.font-family",
        default: TerminalConfiguration.defaultFontFamily
      ),
      fontSize: try number(terminalTable["font-size"], key: "terminal.font-size", default: 13),
      theme: try string(terminalTable["theme"], key: "terminal.theme", default: ThemeCatalog.darkDefault.name),
      cursorShape: try enumValue(
        terminalTable["cursor-shape"], key: "terminal.cursor-shape", default: CursorShape.block),
      cursorBlink: try boolean(terminalTable["cursor-blink"], key: "terminal.cursor-blink", default: false),
      scrollbackCapacity: try integer(
        terminalTable["scrollback-capacity"], key: "terminal.scrollback-capacity", default: 100_000),
      boldIsBright: try boolean(
        terminalTable["bold-is-bright"], key: "terminal.bold-is-bright", default: false),
      minimumContrast: try number(
        terminalTable["minimum-contrast"], key: "terminal.minimum-contrast", default: 1)
    )
    let rooms = try arrayOfTables(root["rooms"], key: "rooms", default: [])
      .enumerated().map { try room(from: $0.element, index: $0.offset) }
    let hostTables = try arrayOfTables(root["hosts"], key: "hosts", default: [])
    let hosts = try hostTables.enumerated().map { try host(from: $0.element, index: $0.offset) }
    let notifications = try table(root["notifications"], key: "notifications", default: [:])
    let board = try table(root["board"], key: "board", default: [:])
    let speech = try table(root["speech"], key: "speech", default: [:])
    let mcp = try table(root["mcp"], key: "mcp", default: [:])
    return Configuration(
      terminal: terminal,
      rooms: root["rooms"] == nil ? [.personal, .work] : rooms,
      hosts: hosts,
      earconsEnabled: try boolean(
        notifications["earcons-enabled"], key: "notifications.earcons-enabled", default: false),
      boardPresentation: try enumValue(
        board["presentation"], key: "board.presentation", default: BoardPresentation.comfortable),
      dictationKey: try string(speech["dictation-key"], key: "speech.dictation-key", default: "fn fn"),
      mcpEnabled: try boolean(mcp["enabled"], key: "mcp.enabled", default: false)
    )
  }

  private func document() -> TOMLDocument {
    let sourceRoot = sourceDocument?.root ?? [:]
    let existingRoomTables = Self.tablesByIdentity(
      sourceRoot["rooms"],
      identityKey: "id"
    )
    let roomValues = rooms.map { room -> TOMLValue in
      let id = room.id.rawValue.uuidString
      var table = existingRoomTables[id] ?? [:]
      let destination: String
      switch room.defaults.destination {
      case .local:
        destination = "local"
        table.removeValue(forKey: "default-host")
      case let .host(alias):
        destination = "host"
        table["default-host"] = .string(alias.rawValue)
      }
      table["id"] = .string(id)
      table["name"] = .string(room.name)
      table["tint"] = .string(Self.colorHex(room.baseTint))
      table["terminal-theme"] = .string(room.terminalThemeName)
      table["host-aliases"] = .array(
        room.hostAliases.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }
      )
      table["enabled-earcons"] = .array(
        room.notificationRules.enabledEarcons.sorted { $0.rawValue < $1.rawValue }
          .map { .string($0.rawValue) }
      )
      table["default-destination"] = .string(destination)
      table["adapter-servers"] = .array(room.adapterServers.sorted(by: Self.adapterOrder).map {
        .table(["adapter": .string($0.adapterIdentifier), "server": .string($0.serverIdentifier)])
      })
      table["session-mappings"] = .array(
        room.sessionMappings.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
          .map { .string($0.rawValue.uuidString) }
      )
      table["pane-mappings"] = .array(
        room.paneMappings.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
          .map { .string($0.rawValue.uuidString) }
      )
      table["workspace-mappings"] = .array(room.workspaceMappings.sorted(by: Self.workspaceOrder).map {
        .table(["adapter": .string($0.adapterIdentifier), "workspace": .string($0.workspaceIdentifier)])
      })
      if let directory = room.defaults.workingDirectory {
        table["default-working-directory"] = .string(directory)
      } else {
        table.removeValue(forKey: "default-working-directory")
      }
      return .table(table)
    }
    let existingHostTables = Self.tablesByIdentity(
      sourceRoot["hosts"],
      identityKey: "alias"
    )
    let hostValues = hosts.map { host -> TOMLValue in
      var table = existingHostTables[host.alias.rawValue] ?? [:]
      table["alias"] = .string(host.alias.rawValue)
      table["hostname"] = .string(host.hostname)
      table["port"] = .integer(Int64(host.port))
      if let user = host.user {
        table["user"] = .string(user)
      } else {
        table.removeValue(forKey: "user")
      }
      return .table(table)
    }
    var root = sourceRoot
    root["terminal"] = mergedTable(
      sourceRoot["terminal"],
      values: [
        "font-family": .string(terminal.fontFamily),
        "font-size": .float(terminal.fontSize),
        "theme": .string(terminal.theme),
        "cursor-shape": .string(terminal.cursorShape.rawValue),
        "cursor-blink": .boolean(terminal.cursorBlink),
        "scrollback-capacity": .integer(Int64(terminal.scrollbackCapacity)),
        "bold-is-bright": .boolean(terminal.boldIsBright),
        "minimum-contrast": .float(terminal.minimumContrast),
      ]
    )
    root["rooms"] = .array(roomValues)
    root["hosts"] = .array(hostValues)
    root["notifications"] = mergedTable(
      sourceRoot["notifications"],
      values: ["earcons-enabled": .boolean(earconsEnabled)]
    )
    root["board"] = mergedTable(
      sourceRoot["board"],
      values: ["presentation": .string(boardPresentation.rawValue)]
    )
    root["speech"] = mergedTable(
      sourceRoot["speech"],
      values: ["dictation-key": .string(dictationKey)]
    )
    root["mcp"] = mergedTable(
      sourceRoot["mcp"],
      values: ["enabled": .boolean(mcpEnabled)]
    )
    return TOMLDocument(root: root)
  }

  private func mergedTable(
    _ existingValue: TOMLValue?,
    values: [String: TOMLValue]
  ) -> TOMLValue {
    var table: [String: TOMLValue]
    if case let .table(existing)? = existingValue {
      table = existing
    } else {
      table = [:]
    }
    table.merge(values) { _, replacement in replacement }
    return .table(table)
  }

  private static func tablesByIdentity(
    _ value: TOMLValue?,
    identityKey: String
  ) -> [String: [String: TOMLValue]] {
    guard case let .array(values)? = value else { return [:] }
    var result: [String: [String: TOMLValue]] = [:]
    for value in values {
      guard case let .table(table) = value,
            case let .string(identity)? = table[identityKey] else { continue }
      result[identity] = table
    }
    return result
  }

  private static func room(from table: [String: TOMLValue], index: Int) throws -> Room {
    let prefix = "rooms[\(index)]"
    let idText = try string(table["id"], key: "\(prefix).id")
    guard let uuid = UUID(uuidString: idText) else {
      throw configError(key: "\(prefix).id", cause: "Room identifier is not a UUID")
    }
    let tintText = try string(table["tint"], key: "\(prefix).tint")
    guard let tint = TokenColor(hex: tintText) else {
      throw configError(key: "\(prefix).tint", cause: "Room tint must be #rrggbb or #rrggbbaa")
    }
    let destinationName = try string(
      table["default-destination"], key: "\(prefix).default-destination", default: "local")
    let destination: RoomDestination
    if destinationName == "local" {
      destination = .local
    } else if destinationName == "host" {
      destination = .host(HostAlias(try string(table["default-host"], key: "\(prefix).default-host")))
    } else {
      throw configError(key: "\(prefix).default-destination", cause: "Destination must be local or host")
    }
    let adapterTables = try arrayOfTables(table["adapter-servers"], key: "\(prefix).adapter-servers", default: [])
    let adapters = try adapterTables.enumerated().map { adapterIndex, adapter in
      AdapterServerReference(
        adapterIdentifier: try string(
          adapter["adapter"], key: "\(prefix).adapter-servers[\(adapterIndex)].adapter"),
        serverIdentifier: try string(
          adapter["server"], key: "\(prefix).adapter-servers[\(adapterIndex)].server")
      )
    }
    let workspaceTables = try arrayOfTables(
      table["workspace-mappings"],
      key: "\(prefix).workspace-mappings",
      default: []
    )
    let workspaces = try workspaceTables.enumerated().map { workspaceIndex, workspace in
      AdapterWorkspaceReference(
        adapterIdentifier: try string(
          workspace["adapter"],
          key: "\(prefix).workspace-mappings[\(workspaceIndex)].adapter"
        ),
        workspaceIdentifier: try string(
          workspace["workspace"],
          key: "\(prefix).workspace-mappings[\(workspaceIndex)].workspace"
        )
      )
    }
    let sessions = try identifierValues(
      table["session-mappings"],
      key: "\(prefix).session-mappings"
    ).map { SessionID(rawValue: $0) }
    let panes = try identifierValues(
      table["pane-mappings"],
      key: "\(prefix).pane-mappings"
    ).map { PaneID(rawValue: $0) }
    let earcons = try stringArray(table["enabled-earcons"], key: "\(prefix).enabled-earcons", default: [])
    let parsedEarcons = try Set(earcons.map { value -> Earcon in
      guard let earcon = Earcon(rawValue: value) else {
        throw configError(key: "\(prefix).enabled-earcons", cause: "Unknown earcon \(value)")
      }
      return earcon
    })
    return Room(
      id: RoomID(rawValue: uuid),
      name: try string(table["name"], key: "\(prefix).name"),
      baseTint: tint,
      terminalThemeName: try string(table["terminal-theme"], key: "\(prefix).terminal-theme"),
      hostAliases: Set(try stringArray(table["host-aliases"], key: "\(prefix).host-aliases", default: [])
        .map { HostAlias($0) }),
      adapterServers: Set(adapters),
      sessionMappings: Set(sessions),
      paneMappings: Set(panes),
      workspaceMappings: Set(workspaces),
      notificationRules: NotificationRules(enabledEarcons: parsedEarcons),
      defaults: RoomDefaults(
        destination: destination,
        workingDirectory: try optionalString(
          table["default-working-directory"], key: "\(prefix).default-working-directory")
      )
    )
  }

  private static func host(from table: [String: TOMLValue], index: Int) throws -> HostConfiguration {
    let prefix = "hosts[\(index)]"
    return HostConfiguration(
      alias: HostAlias(try string(table["alias"], key: "\(prefix).alias")),
      hostname: try string(table["hostname"], key: "\(prefix).hostname"),
      user: try optionalString(table["user"], key: "\(prefix).user"),
      port: try integer(table["port"], key: "\(prefix).port", default: 22)
    )
  }

  private static func adapterOrder(_ lhs: AdapterServerReference, _ rhs: AdapterServerReference) -> Bool {
    lhs.adapterIdentifier == rhs.adapterIdentifier
      ? lhs.serverIdentifier < rhs.serverIdentifier
      : lhs.adapterIdentifier < rhs.adapterIdentifier
  }

  private static func workspaceOrder(
    _ lhs: AdapterWorkspaceReference,
    _ rhs: AdapterWorkspaceReference
  ) -> Bool {
    lhs.adapterIdentifier == rhs.adapterIdentifier
      ? lhs.workspaceIdentifier < rhs.workspaceIdentifier
      : lhs.adapterIdentifier < rhs.adapterIdentifier
  }

  private static func colorHex(_ color: TokenColor) -> String {
    guard color.alpha < 1 else { return color.hexString }
    let alpha = Int((color.alpha * 255).rounded())
    return color.hexString + String(format: "%02x", alpha)
  }

  private static func table(
    _ value: TOMLValue?, key: String, default defaultValue: [String: TOMLValue]? = nil
  ) throws -> [String: TOMLValue] {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .table(result)? = value else { throw configError(key: key, cause: "Expected a table") }
    return result
  }

  private static func arrayOfTables(
    _ value: TOMLValue?, key: String, default defaultValue: [[String: TOMLValue]]? = nil
  ) throws -> [[String: TOMLValue]] {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .array(values)? = value else { throw configError(key: key, cause: "Expected an array of tables") }
    return try values.enumerated().map { index, value in
      guard case let .table(table) = value else {
        throw configError(key: "\(key)[\(index)]", cause: "Expected a table")
      }
      return table
    }
  }

  private static func string(_ value: TOMLValue?, key: String, default defaultValue: String? = nil) throws -> String {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .string(result)? = value else { throw configError(key: key, cause: "Expected a string") }
    return result
  }

  private static func optionalString(_ value: TOMLValue?, key: String) throws -> String? {
    guard value != nil else { return nil }
    return try string(value, key: key)
  }

  private static func stringArray(
    _ value: TOMLValue?, key: String, default defaultValue: [String]? = nil
  ) throws -> [String] {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .array(values)? = value else { throw configError(key: key, cause: "Expected an array") }
    return try values.enumerated().map { index, value in
      guard case let .string(result) = value else {
        throw configError(key: "\(key)[\(index)]", cause: "Expected a string")
      }
      return result
    }
  }

  private static func boolean(_ value: TOMLValue?, key: String, default defaultValue: Bool? = nil) throws -> Bool {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .boolean(result)? = value else { throw configError(key: key, cause: "Expected a boolean") }
    return result
  }

  private static func integer(_ value: TOMLValue?, key: String, default defaultValue: Int? = nil) throws -> Int {
    if value == nil, let defaultValue { return defaultValue }
    guard case let .integer(result)? = value, let converted = Int(exactly: result) else {
      throw configError(key: key, cause: "Expected an integer")
    }
    return converted
  }

  private static func number(_ value: TOMLValue?, key: String, default defaultValue: Double? = nil) throws -> Double {
    if value == nil, let defaultValue { return defaultValue }
    switch value {
    case let .float(result)?: return result
    case let .integer(result)?: return Double(result)
    default: throw configError(key: key, cause: "Expected a number")
    }
  }

  private static func enumValue<Value: RawRepresentable>(
    _ value: TOMLValue?, key: String, default defaultValue: Value
  ) throws -> Value where Value.RawValue == String {
    guard value != nil else { return defaultValue }
    let rawValue = try string(value, key: key)
    guard let result = Value(rawValue: rawValue) else {
      throw configError(key: key, cause: "Unknown value \(rawValue)")
    }
    return result
  }

  private func require(_ condition: @autoclosure () -> Bool, key: String, cause: String) throws {
    guard condition() else { throw Self.configError(key: key, cause: cause) }
  }

  private static func identifierValues(
    _ value: TOMLValue?,
    key: String
  ) throws -> [UUID] {
    try stringArray(value, key: key, default: []).enumerated().map { index, rawValue in
      guard let identifier = UUID(uuidString: rawValue) else {
        throw configError(key: "\(key)[\(index)]", cause: "Expected a UUID")
      }
      return identifier
    }
  }
  fileprivate static func configError(key: String, cause: String) -> AllwardError {
    AllwardError(domain: .config, operation: key, cause: cause, recovery: "Correct \(key) and reload the config")
  }
}

public enum ConfigurationReloadEvent: Sendable {
  case configuration(Configuration)
  case failure(AllwardError)
}

public actor ConfigurationReloader {

  private let url: URL
  private var lastGood: Configuration
  private var fileSource: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var directoryDescriptor: Int32 = -1
  private var fileCancellationPending = false
  private var continuations: [UUID: AsyncStream<ConfigurationReloadEvent>.Continuation] = [:]

  public init(url: URL, initial: Configuration) {
    self.url = url
    lastGood = initial
  }

  deinit {
    if let fileSource {
      fileSource.cancel()
    } else if fileDescriptor >= 0 {
      close(fileDescriptor)
    }
    if let directorySource {
      directorySource.cancel()
    } else if directoryDescriptor >= 0 {
      close(directoryDescriptor)
    }
  }

  public func start() throws {
    guard fileSource == nil, directorySource == nil else { return }
    do {
      try installDirectoryWatch()
      try installFileWatch()
    } catch {
      stop()
      throw error
    }
  }

  public func stop() {
    fileSource?.cancel()
    directorySource?.cancel()
    fileSource = nil
    directorySource = nil
    fileDescriptor = -1
    directoryDescriptor = -1
  }

  private func installFileWatch() throws {
    fileDescriptor = open(url.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      throw Configuration.configError(key: "config.watch", cause: "Unable to watch the config file")
    }
    let watchedDescriptor = fileDescriptor
    let newSource = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: watchedDescriptor,
      eventMask: [.write, .rename, .delete],
      queue: DispatchQueue.global(qos: .utility)
    )
    newSource.setEventHandler { [weak self] in
      Task { await self?.handleFileEvent() }
    }
    newSource.setCancelHandler { [weak self] in
      close(watchedDescriptor)
      Task { await self?.fileWatchDidCancel() }
    }
    fileSource = newSource
    newSource.resume()
  }

  private func installDirectoryWatch() throws {
    directoryDescriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard directoryDescriptor >= 0 else {
      throw Configuration.configError(key: "config.watch", cause: "Unable to watch the config directory")
    }
    let watchedDescriptor = directoryDescriptor
    let newSource = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: watchedDescriptor,
      eventMask: .write,
      queue: DispatchQueue.global(qos: .utility)
    )
    newSource.setEventHandler { [weak self] in
      Task { await self?.handleDirectoryEvent() }
    }
    newSource.setCancelHandler { close(watchedDescriptor) }
    directorySource = newSource
    newSource.resume()
  }

  private func handleFileEvent() {
    let events = fileSource?.data ?? []
    reload()
    guard events.contains(.rename) || events.contains(.delete) else { return }
    fileCancellationPending = true
    fileSource?.cancel()
    fileSource = nil
    fileDescriptor = -1
  }

  private func handleDirectoryEvent() {
    reload()
    guard fileSource == nil, !fileCancellationPending else { return }
    do {
      try installFileWatch()
    } catch {
      publishWatchFailure(error)
    }
  }

  private func fileWatchDidCancel() {
    fileCancellationPending = false
    guard directorySource != nil, fileSource == nil else { return }
    do {
      try installFileWatch()
    } catch {
      publishWatchFailure(error)
    }
  }

  private func publishWatchFailure(_ error: Error) {
    let allwardError = error as? AllwardError ?? Configuration.configError(
      key: "config.watch", cause: "File watch failed: \(error.localizedDescription)")
    continuations.values.forEach { $0.yield(.failure(allwardError)) }
  }

  public func events() -> AsyncStream<ConfigurationReloadEvent> {
    let id = UUID()
    let pair = AsyncStream<ConfigurationReloadEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuations[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    pair.continuation.yield(.configuration(lastGood))
    return pair.stream
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }

  private func reload() {
    do {
      var loaded = try Configuration.load(from: url)
      var comparableLoaded = loaded
      var comparableLastGood = lastGood
      comparableLoaded.generation = .initial
      comparableLastGood.generation = .initial
      guard comparableLoaded != comparableLastGood else { return }
      loaded.generation = lastGood.generation.next
      lastGood = loaded
      continuations.values.forEach { $0.yield(.configuration(loaded)) }
    } catch let error as AllwardError {
      continuations.values.forEach { $0.yield(.failure(error)) }
    } catch {
      let wrapped = Configuration.configError(
        key: "config.reload", cause: "Reload failed: \(error.localizedDescription)")
      continuations.values.forEach { $0.yield(.failure(wrapped)) }
    }
  }
}
