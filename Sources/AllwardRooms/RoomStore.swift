import Foundation
import AllwardCore
import AllwardDesign

public struct ResolvedRoomTint: Hashable, Sendable {
  public let seam: TokenColor
  public let wash: TokenColor
  public let focus: TokenColor
  public let board: TokenColor
  public let router: TokenColor
  public let ambient: TokenColor
  public let material: TokenColor

  public init(baseTint: TokenColor, appearance: Appearance, settings: AccessibilitySettings) {
    let palette = DesignPalette(appearance: appearance, settings: settings, roomTint: baseTint)
    seam = palette[.seam]
    wash = palette[.wash]
    focus = palette[.focus]
    board = palette[.board]
    router = palette[.router]
    ambient = palette[.ambient]
    material = palette[.material]
  }
}

public struct RoomPolicySnapshot: Hashable, Sendable {
  public let generation: Generation
  public let windowID: WindowID
  public let activeRoom: Room
  public let resolvedTint: ResolvedRoomTint
  public let notificationRules: NotificationRules
  public let focusPolicy: FocusPolicy

  public var allowsAmbientPresentation: Bool { focusPolicy.allowsAmbientPresentation }

  public init(
    generation: Generation,
    windowID: WindowID,
    activeRoom: Room,
    resolvedTint: ResolvedRoomTint,
    notificationRules: NotificationRules,
    focusPolicy: FocusPolicy
  ) {
    self.generation = generation
    self.windowID = windowID
    self.activeRoom = activeRoom
    self.resolvedTint = resolvedTint
    self.notificationRules = notificationRules
    self.focusPolicy = focusPolicy
  }
}

public actor RoomStore {
  private struct Subscription {
    let windowID: WindowID
    let appearance: Appearance
    let settings: AccessibilitySettings
    let continuation: AsyncStream<RoomPolicySnapshot>.Continuation
  }

  private var roomsByID: [RoomID: Room]
  private var roomByHost: [HostAlias: RoomID]
  private var roomByAdapterServer: [AdapterServerReference: RoomID]
  private var roomBySession: [SessionID: RoomID]
  private var roomByPane: [PaneID: RoomID]
  private var roomByWorkspace: [AdapterWorkspaceReference: RoomID]
  private var activeRoomByWindow: [WindowID: RoomID] = [:]
  private var generation = Generation.initial
  private var subscriptions: [UUID: Subscription] = [:]
  private let defaultRoomID: RoomID
  private let focusProvider: any FocusFilterProviding

  public init(
    rooms: [Room] = [.personal, .work],
    defaultRoomID: RoomID = Room.personal.id,
    focusProvider: any FocusFilterProviding = StaticFocusFilterProvider()
  ) {
    precondition(!rooms.isEmpty, "RoomStore requires at least one Room")
    let indexed = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    precondition(indexed.count == rooms.count, "Room identifiers must be unique")
    precondition(indexed[defaultRoomID] != nil, "The default Room must exist")
    let associations = Self.associations(for: rooms)
    precondition(associations.hosts.count == rooms.reduce(0) { $0 + $1.hostAliases.count },
                 "Host aliases must belong to only one Room")
    precondition(associations.adapterServers.count == rooms.reduce(0) { $0 + $1.adapterServers.count },
                 "Adapter servers must belong to only one Room")
    precondition(associations.sessions.count == rooms.reduce(0) { $0 + $1.sessionMappings.count },
                 "Sessions must belong to only one Room")
    precondition(associations.panes.count == rooms.reduce(0) { $0 + $1.paneMappings.count },
                 "Panes must belong to only one Room")
    precondition(associations.workspaces.count == rooms.reduce(0) { $0 + $1.workspaceMappings.count },
                 "Workspaces must belong to only one Room")
    roomsByID = indexed
    roomByHost = associations.hosts
    roomByAdapterServer = associations.adapterServers
    roomBySession = associations.sessions
    roomByPane = associations.panes
    roomByWorkspace = associations.workspaces
    self.defaultRoomID = defaultRoomID
    self.focusProvider = focusProvider
  }

  public func rooms() -> [Room] {
    roomsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func room(id: RoomID) -> Room? {
    roomsByID[id]
  }

  public func resolvedRoom(
    sessionID: SessionID? = nil,
    paneID: PaneID? = nil,
    workspace: AdapterWorkspaceReference? = nil,
    adapterServer: AdapterServerReference? = nil,
    hostAlias: HostAlias? = nil
  ) -> Room {
    let mappedRoomID = sessionID.flatMap { roomBySession[$0] }
      ?? paneID.flatMap { roomByPane[$0] }
      ?? workspace.flatMap { roomByWorkspace[$0] }
      ?? adapterServer.flatMap { roomByAdapterServer[$0] }
      ?? hostAlias.flatMap { roomByHost[$0] }
      ?? defaultRoomID
    return roomsByID[mappedRoomID] ?? roomsByID[defaultRoomID]!
  }

  public func activeRoom(for windowID: WindowID) -> Room {
    let roomID = activeRoomByWindow[windowID] ?? defaultRoomID
    return roomsByID[roomID] ?? roomsByID[defaultRoomID]!
  }

  public func setActiveRoom(_ roomID: RoomID, for windowID: WindowID) async throws {
    guard roomsByID[roomID] != nil else {
      throw roomError(key: "rooms.active", cause: "Room \(roomID) is not configured")
    }
    guard activeRoomByWindow[windowID] != roomID else { return }
    activeRoomByWindow[windowID] = roomID
    generation = generation.next
    await publish(windowID: windowID)
  }

  public func replaceRooms(_ rooms: [Room]) async throws {
    guard !rooms.isEmpty else {
      throw roomError(key: "rooms", cause: "At least one Room is required")
    }
    let indexed = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard indexed.count == rooms.count else {
      throw roomError(key: "rooms.id", cause: "Room identifiers must be unique")
    }
    guard indexed[defaultRoomID] != nil else {
      throw roomError(key: "rooms.default", cause: "The default Room cannot be removed")
    }
    let missingActive = activeRoomByWindow.values.first { indexed[$0] == nil }
    guard missingActive == nil else {
      throw roomError(key: "rooms.active", cause: "An active Room cannot be removed")
    }
    let associations = Self.associations(for: rooms)
    guard associations.hosts.count == rooms.reduce(0, { $0 + $1.hostAliases.count }) else {
      throw roomError(key: "rooms.host-aliases", cause: "A host alias cannot belong to more than one Room")
    }
    guard associations.adapterServers.count == rooms.reduce(0, { $0 + $1.adapterServers.count }) else {
      throw roomError(
        key: "rooms.adapter-servers",
        cause: "An adapter server cannot belong to more than one Room"
      )
    }
    guard associations.sessions.count == rooms.reduce(0, { $0 + $1.sessionMappings.count }) else {
      throw roomError(key: "rooms.session-mappings", cause: "A session cannot belong to more than one Room")
    }
    guard associations.panes.count == rooms.reduce(0, { $0 + $1.paneMappings.count }) else {
      throw roomError(key: "rooms.pane-mappings", cause: "A pane cannot belong to more than one Room")
    }
    guard associations.workspaces.count == rooms.reduce(0, { $0 + $1.workspaceMappings.count }) else {
      throw roomError(key: "rooms.workspace-mappings", cause: "A workspace cannot belong to more than one Room")
    }
    roomsByID = indexed
    roomByHost = associations.hosts
    roomByAdapterServer = associations.adapterServers
    roomBySession = associations.sessions
    roomByPane = associations.panes
    roomByWorkspace = associations.workspaces
    generation = generation.next
    await publishAll()
  }

  public func refreshFocusPolicies() async {
    generation = generation.next
    await publishAll()
  }

  public func snapshot(
    for windowID: WindowID,
    appearance: Appearance,
    settings: AccessibilitySettings = .standard
  ) async -> RoomPolicySnapshot {
    while true {
      let snapshotGeneration = generation
      let room = activeRoom(for: windowID)
      let tint = ResolvedRoomTint(
        baseTint: room.baseTint,
        appearance: appearance,
        settings: settings
      )
      let policy = await focusProvider.policy(for: room.id)
      guard generation == snapshotGeneration, activeRoom(for: windowID).id == room.id else { continue }
      return RoomPolicySnapshot(
        generation: snapshotGeneration,
        windowID: windowID,
        activeRoom: room,
        resolvedTint: tint,
        notificationRules: room.notificationRules,
        focusPolicy: policy
      )
    }
  }

  public func snapshots(
    for windowID: WindowID,
    appearance: Appearance,
    settings: AccessibilitySettings = .standard
  ) async -> AsyncStream<RoomPolicySnapshot> {
    let id = UUID()
    let pair = AsyncStream<RoomPolicySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    subscriptions[id] = Subscription(
      windowID: windowID,
      appearance: appearance,
      settings: settings,
      continuation: pair.continuation
    )
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscription(id) }
    }
    pair.continuation.yield(await snapshot(for: windowID, appearance: appearance, settings: settings))
    return pair.stream
  }

  private func removeSubscription(_ id: UUID) {
    subscriptions.removeValue(forKey: id)
  }

  private func publish(windowID: WindowID) async {
    for subscription in subscriptions.values where subscription.windowID == windowID {
      let value = await snapshot(
        for: subscription.windowID,
        appearance: subscription.appearance,
        settings: subscription.settings
      )
      subscription.continuation.yield(value)
    }
  }

  private func publishAll() async {
    for subscription in subscriptions.values {
      let value = await snapshot(
        for: subscription.windowID,
        appearance: subscription.appearance,
        settings: subscription.settings
      )
      subscription.continuation.yield(value)
    }
  }

  private static func associations(
    for rooms: [Room]
  ) -> (
    hosts: [HostAlias: RoomID],
    adapterServers: [AdapterServerReference: RoomID],
    sessions: [SessionID: RoomID],
    panes: [PaneID: RoomID],
    workspaces: [AdapterWorkspaceReference: RoomID]
  ) {
    let hosts = associationMap(rooms) { $0.hostAliases }
    let adapterServers = associationMap(rooms) { $0.adapterServers }
    let sessions = associationMap(rooms) { $0.sessionMappings }
    let panes = associationMap(rooms) { $0.paneMappings }
    let workspaces = associationMap(rooms) { $0.workspaceMappings }
    return (hosts, adapterServers, sessions, panes, workspaces)
  }

  private static func associationMap<Key: Hashable>(
    _ rooms: [Room],
    keys: (Room) -> Set<Key>
  ) -> [Key: RoomID] {
    Dictionary(
      rooms.flatMap { room in keys(room).map { ($0, room.id) } },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func roomError(key: String, cause: String) -> AllwardError {
    AllwardError(domain: .config, operation: key, cause: cause, recovery: "Review the Room configuration")
  }
}
