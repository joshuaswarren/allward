import AllwardCore
import AllwardSurfaces
import Foundation

extension ControlService {
    public func boardSnapshot() async -> BoardSnapshot {
        await surfaceStore.snapshot().board
    }

    public func routerSnapshot() async -> RouterSnapshot {
        await surfaceStore.snapshot().router
    }

    public func staleMCPAuthority(namespace: String) async {
        _ = await surfaceStore.staleMCPAuthority(namespace: namespace)
    }

    public func createAuthoredRecord(
        target: Target,
        generation: Generation,
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        idempotencyKey: IdempotencyKey
    ) async -> AuthoredMutationResult {
        await authoredResult(
            kind: .createAuthoredRecord,
            target: target,
            generation: generation,
            idempotencyKey: idempotencyKey
        ) {
            try await self.surfaceStore.createMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                content: content,
                target: target,
                authority: authority,
                invocationID: invocationID
            )
        }
    }

    public func updateAuthoredRecord(
        target: Target,
        generation: Generation,
        callerLogicalKey: String,
        content: MCPAuthoredContent,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        idempotencyKey: IdempotencyKey
    ) async -> AuthoredMutationResult {
        await authoredResult(
            kind: .updateAuthoredRecord,
            target: target,
            generation: generation,
            idempotencyKey: idempotencyKey
        ) {
            try await self.surfaceStore.updateMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                content: content,
                target: target,
                authority: authority,
                invocationID: invocationID,
                expectedRevision: expectedRevision
            )
        }
    }

    public func endAuthoredRecord(
        target: Target,
        generation: Generation,
        callerLogicalKey: String,
        authority: MCPAuthoredAuthority,
        invocationID: UUID,
        expectedRevision: UInt64,
        reason: String,
        idempotencyKey: IdempotencyKey
    ) async -> AuthoredMutationResult {
        await authoredResult(
            kind: .endAuthoredRecord,
            target: target,
            generation: generation,
            idempotencyKey: idempotencyKey
        ) {
            try await self.surfaceStore.endMCPAuthored(
                callerLogicalKey: callerLogicalKey,
                target: target,
                authority: authority,
                invocationID: invocationID,
                expectedRevision: expectedRevision,
                reason: reason
            )
        }
    }

    public func recoverAuthoredMutation(
        _ key: IdempotencyKey
    ) async -> AuthoredMutationResult? {
        try? await ledger.lookup(key, as: AuthoredMutationResult.self)
    }

    private func authoredResult(
        kind: ControlMutationKind,
        target: Target,
        generation: Generation,
        idempotencyKey: IdempotencyKey,
        operation: @escaping @Sendable () async throws -> MCPAuthoredMutationReceipt
    ) async -> AuthoredMutationResult {
        do {
            return try await ledger.perform(key: idempotencyKey) {
                if let rejection = await self.registry.rejection(
                    for: target,
                    expectedGeneration: generation
                ) {
                    return .rejected(rejection)
                }
                do {
                    let result = try await operation()
                    let outcome = AuthoredMutationOutcome(
                        status: result.status.rawValue,
                        recordID: result.recordID,
                        incarnation: result.incarnation,
                        revision: result.revision,
                        sourceEventID: result.sourceEventID,
                        commitOrdinal: result.commitOrdinal
                    )
                    let controlReceipt = await self.receipt(
                        kind: kind,
                        target: target,
                        change: RegistryChange(before: generation, after: generation),
                        pane: target.pane
                    )
                    return .completed(outcome, controlReceipt)
                } catch {
                    return .rejected(await self.controlFailure(operation: "mcp-authored", error: error))
                }
            }
        } catch {
            return .rejected(controlFailure(operation: "mcp-authored-idempotency", error: error))
        }
    }
}
