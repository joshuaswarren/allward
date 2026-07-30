import AllwardCore
import AllwardSurfaces
import Foundation

public enum MCPAuthoredFreshness: String, Codable, Hashable, Sendable, CaseIterable {
    case live
    case stale
    case ended
    case superseded
}

public enum MCPAuthoredAuthorityLossReason: String, Codable, Hashable, Sendable {
    case clientDisconnected
    case grantExpired
    case grantRevoked
    case serverRelaunched
    case presenterReplaced
}

public enum MCPAuthoredLifecycleError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidLogicalKey(String)
    case emptyTitle

    public var description: String {
        switch self {
        case let .invalidLogicalKey(reason): "Invalid caller_logical_record_key: \(reason)"
        case .emptyTitle: "MCP-authored record title must not be empty"
        }
    }
}

public struct MCPAuthoredRecordLifecycle: Sendable {
    private let store: SurfaceStore

    public init(store: SurfaceStore) {
        self.store = store
    }

    public func create(
        logicalKey: String,
        content: AllwardSurfaces.MCPAuthoredContent,
        target: Target,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID
    ) async throws -> AllwardSurfaces.MCPAuthoredMutationReceipt {
        try Self.validate(logicalKey: logicalKey, content: content)
        return try await store.createMCPAuthored(
            callerLogicalKey: logicalKey,
            content: content,
            target: target,
            authority: authority,
            invocationID: invocationID
        )
    }

    public func update(
        logicalKey: String,
        content: AllwardSurfaces.MCPAuthoredContent,
        target: Target,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64
    ) async throws -> AllwardSurfaces.MCPAuthoredMutationReceipt {
        try Self.validate(logicalKey: logicalKey, content: content)
        return try await store.updateMCPAuthored(
            callerLogicalKey: logicalKey,
            content: content,
            target: target,
            authority: authority,
            invocationID: invocationID,
            expectedRevision: expectedRevision
        )
    }

    public func end(
        logicalKey: String,
        target: Target,
        authority: AllwardSurfaces.MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String
    ) async throws -> AllwardSurfaces.MCPAuthoredMutationReceipt {
        try Self.validate(logicalKey: logicalKey)
        return try await store.endMCPAuthored(
            callerLogicalKey: logicalKey,
            target: target,
            authority: authority,
            invocationID: invocationID,
            expectedRevision: expectedRevision,
            reason: reason
        )
    }

    public func loseAuthority(
        _ authority: AllwardSurfaces.MCPAuthoredAuthority,
        reason: MCPAuthoredAuthorityLossReason
    ) async {
        _ = await store.staleMCPAuthority(namespace: authority.grantInvocationNamespace)
    }

    public static func validate(
        logicalKey: String,
        content: AllwardSurfaces.MCPAuthoredContent? = nil
    ) throws {
        let key = logicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MCPAuthoredLifecycleError.invalidLogicalKey("must not be empty") }
        guard key.count <= 128 else { throw MCPAuthoredLifecycleError.invalidLogicalKey("exceeds 128 characters") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard key.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MCPAuthoredLifecycleError.invalidLogicalKey("use only letters, numbers, dot, underscore, and hyphen")
        }
        let reserved = ["publisher", "agent", "adapter", "source", "address"]
        guard !reserved.contains(where: { key.lowercased().hasPrefix($0 + ".") }) else {
            throw MCPAuthoredLifecycleError.invalidLogicalKey("publisher-shaped identity prefixes are receiver-owned")
        }
        if let content, content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPAuthoredLifecycleError.emptyTitle
        }
    }
}
