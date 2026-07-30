import AllwardCore

public enum FocusPolicy: String, Codable, Hashable, Sendable, CaseIterable {
  case allow
  case deny

  public var allowsAmbientPresentation: Bool { self == .allow }
}

public protocol FocusFilterProviding: Sendable {
  func policy(for roomID: RoomID) async -> FocusPolicy
}

public struct StaticFocusFilterProvider: FocusFilterProviding, Sendable {
  public var policies: [RoomID: FocusPolicy]
  public var defaultPolicy: FocusPolicy

  public init(policies: [RoomID: FocusPolicy] = [:], defaultPolicy: FocusPolicy = .allow) {
    self.policies = policies
    self.defaultPolicy = defaultPolicy
  }

  public func policy(for roomID: RoomID) async -> FocusPolicy {
    policies[roomID] ?? defaultPolicy
  }
}
