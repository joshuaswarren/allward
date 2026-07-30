import AllwardCore
import Foundation

extension ControlService {
    /// Drag-resize of a split divider. It is a layout mutation like any other:
    /// it carries a target and a generation, and a stale generation is refused
    /// rather than silently applied.
    public func resizeDivider(
        target: Target,
        generation: Generation,
        pane: PaneID,
        path: SplitPath,
        ratio: Double,
        idempotencyKey: IdempotencyKey
    ) async -> ControlMutationResult {
        await recordedMutation(idempotencyKey) {
            switch await self.registry.resizeDivider(
                containing: pane, path: path, ratio: ratio, expectedGeneration: generation
            ) {
            case let .success(change):
                return .applied(
                    await self.receipt(
                        kind: .resizePane, target: target, change: change, pane: pane))
            case let .failure(rejection):
                return .rejected(rejection)
            }
        }
    }
}
