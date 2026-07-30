import Foundation
import AllwardCore
import AllwardDesign

public struct AdapterServerReference: Codable, Hashable, Sendable {
  public var adapterIdentifier: String
  public var serverIdentifier: String

  public init(adapterIdentifier: String, serverIdentifier: String) {
    self.adapterIdentifier = adapterIdentifier
    self.serverIdentifier = serverIdentifier
  }
}

public struct AdapterWorkspaceReference: Codable, Hashable, Sendable {
  public var adapterIdentifier: String
  public var workspaceIdentifier: String

  public init(adapterIdentifier: String, workspaceIdentifier: String) {
    self.adapterIdentifier = adapterIdentifier
    self.workspaceIdentifier = workspaceIdentifier
  }
}

public enum RoomDestination: Codable, Hashable, Sendable {
  case local
  case host(HostAlias)

  private enum CodingKeys: String, CodingKey {
    case kind
    case host
  }

  private enum Kind: String, Codable {
    case local
    case host
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .local:
      self = .local
    case .host:
      self = .host(try container.decode(HostAlias.self, forKey: .host))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .local:
      try container.encode(Kind.local, forKey: .kind)
    case let .host(alias):
      try container.encode(Kind.host, forKey: .kind)
      try container.encode(alias, forKey: .host)
    }
  }
}

public struct RoomDefaults: Codable, Hashable, Sendable {
  public var destination: RoomDestination
  public var workingDirectory: String?

  public init(destination: RoomDestination = .local, workingDirectory: String? = nil) {
    self.destination = destination
    self.workingDirectory = workingDirectory
  }
}

public struct NotificationRules: Codable, Hashable, Sendable {
  public var enabledEarcons: Set<Earcon>

  public init(enabledEarcons: Set<Earcon> = []) {
    self.enabledEarcons = enabledEarcons
  }

  public func enables(_ earcon: Earcon, globallyEnabled: Bool) -> Bool {
    globallyEnabled && enabledEarcons.contains(earcon)
  }

  public static let silent = NotificationRules()
}

public struct Room: Codable, Hashable, Sendable, Identifiable {
  public var id: RoomID
  public var name: String
  public var baseTint: TokenColor
  public var terminalThemeName: String
  public var hostAliases: Set<HostAlias>
  public var adapterServers: Set<AdapterServerReference>
  public var sessionMappings: Set<SessionID>
  public var paneMappings: Set<PaneID>
  public var workspaceMappings: Set<AdapterWorkspaceReference>
  public var notificationRules: NotificationRules
  public var defaults: RoomDefaults

  public init(
    id: RoomID = RoomID(),
    name: String,
    baseTint: TokenColor,
    terminalThemeName: String,
    hostAliases: Set<HostAlias> = [],
    adapterServers: Set<AdapterServerReference> = [],
    sessionMappings: Set<SessionID> = [],
    paneMappings: Set<PaneID> = [],
    workspaceMappings: Set<AdapterWorkspaceReference> = [],
    notificationRules: NotificationRules = .silent,
    defaults: RoomDefaults = RoomDefaults()
  ) {
    self.id = id
    self.name = name
    self.baseTint = baseTint
    self.terminalThemeName = terminalThemeName
    self.hostAliases = hostAliases
    self.adapterServers = adapterServers
    self.sessionMappings = sessionMappings
    self.paneMappings = paneMappings
    self.workspaceMappings = workspaceMappings
    self.notificationRules = notificationRules
    self.defaults = defaults
  }

  public static let personal = Room(
    id: RoomID(rawValue: UUID(uuidString: "76F86540-A979-4E97-A29C-B67C94B11482")!),
    name: "Personal",
    baseTint: TokenColor(hex: "#6f8fb7")!,
    terminalThemeName: "Allward Night"
  )

  public static let work = Room(
    id: RoomID(rawValue: UUID(uuidString: "AF63ED41-868B-40AB-B48D-306593C03B5E")!),
    name: "Work",
    baseTint: TokenColor(hex: "#4f927f")!,
    terminalThemeName: "Allward Night"
  )
}
