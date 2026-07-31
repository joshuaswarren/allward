import AllwardControl
import AllwardCore
import Foundation

extension AppModel {
    /// Tabs in reading order for the strip. The title is the focused pane's
    /// session title when there is one, so a tab names its work rather than an
    /// opaque identifier.
    /// The name the native tab bar shows, by the same rule as a pane header.
    public func tabTitle(for tab: TabID) -> String {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }),
            let entry = window.tabs.first(where: { $0.id == tab })
        else { return "Allward" }
        let panes = entry.tree?.leaves ?? []
        guard let pane = entry.focusedPane ?? panes.first,
            let topologyEntry = topology.panes.first(where: { $0.id == pane })
        else { return "Allward" }
        // Before the shell has produced a snapshot the route is still a better
        // name than the app's own, which would repeat on every tab.
        guard let snapshot = paneView(for: pane)?.snapshot else {
            return topologyEntry.destination.provenanceLabel
        }
        return paneTitle(snapshot: snapshot, entry: topologyEntry)
    }

    /// Tabs in reading order, for cycling.
    public func tabOrder() -> [TabID] {
        topology.windows.first { $0.id == focusedWindow }?.tabs.map(\.id) ?? []
    }

    /// A new tab with one local terminal, which is what every Mac terminal does
    /// on the new-tab command.
    public func newTab() async {
        guard let window = focusedWindow,
            let room = topology.windows.first(where: { $0.id == window })?.room
        else { return }
        let tab = TabID()
        let created = await applyingLiveGeneration { generation in
            await control.createTab(
                target: Target(room: room), generation: generation, window: window,
                tab: tab, idempotencyKey: IdempotencyKey(rawValue: UUID().uuidString))
        }
        guard case .applied = created else { return }
        await refreshTopology()
        let request = PaneCreationRequest(
            window: window, tab: tab, geometry: projectedPaneGeometry(),
            workingDirectory: activeRoom?.defaults.workingDirectory, environment: [:])
        await applyingLiveGeneration { generation in
            await control.createLocalPane(
                target: Target(room: room), generation: generation, request: request,
                idempotencyKey: IdempotencyKey(rawValue: UUID().uuidString))
        }
        await refreshTopology()
    }

    public func focusTab(_ tab: TabID) async {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow }),
            let entry = window.tabs.first(where: { $0.id == tab }),
            let pane = entry.focusedPane ?? entry.tree?.leaves.first
        else { return }
        await focus(pane)
    }

    public func closeTab(_ tab: TabID) async {
        guard let window = focusedWindow,
            let room = topology.windows.first(where: { $0.id == window })?.room
        else { return }
        await applyingLiveGeneration { generation in
            await control.closeTab(
                target: Target(room: room), generation: generation, window: window,
                tab: tab, idempotencyKey: IdempotencyKey(rawValue: UUID().uuidString))
        }
        await refreshTopology()
    }

    /// Cycles tabs in reading order, wrapping at both ends.
    public func selectAdjacentTab(forward: Bool) async {
        let order = tabOrder()
        guard order.count > 1, let current = focusedTab,
            let index = order.firstIndex(of: current)
        else { return }
        let step = forward ? 1 : order.count - 1
        await focusTab(order[(index + step) % order.count])
    }
}
