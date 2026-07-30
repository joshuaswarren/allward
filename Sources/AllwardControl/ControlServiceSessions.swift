import AllwardCore
import AllwardTerminal
import Foundation

extension ControlService {
    /// The live session behind a pane. Chrome needs it to subscribe to snapshot
    /// generations; every mutation still goes through the typed operations, so
    /// this stays a read-side accessor.
    public func session(for pane: PaneID) async -> Session? {
        await registry.session(for: pane)
    }

    /// The pane's snapshot stream, or `nil` when the pane no longer exists.
    public func snapshots(for pane: PaneID) async -> AsyncStream<TerminalSnapshot>? {
        await registry.session(for: pane)?.latest
    }

    /// The pane's current target, used to address further operations.
    public func target(for pane: PaneID) async -> Target? {
        await registry.target(for: pane)
    }
}
