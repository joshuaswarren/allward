import AllwardControl
import AllwardCore
import Foundation

extension AppModel {
    /// Tabs in reading order for the strip. The title is the focused pane's
    /// session title when there is one, so a tab names its work rather than an
    /// opaque identifier.
    public func tabStripItems() -> [TabStripItem] {
        guard let window = topology.windows.first(where: { $0.id == focusedWindow })
        else { return [] }
        return window.tabs.enumerated().map { index, tab in
            let panes = tab.tree?.leaves ?? []
            // A tab is named by the same rule as a pane header, so two tabs on
            // the same host do not both read as their route label.
            let named = (tab.focusedPane ?? panes.first).flatMap { pane -> String? in
                guard let snapshot = paneView(for: pane)?.snapshot,
                    let entry = topology.panes.first(where: { $0.id == pane })
                else { return nil }
                return paneTitle(snapshot: snapshot, entry: entry)
            }
            let title = named ?? "Tab \(index + 1)"
            return TabStripItem(id: tab.id, title: title, paneCount: panes.count)
        }
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
        let items = tabStripItems()
        guard items.count > 1, let current = focusedTab,
            let index = items.firstIndex(where: { $0.id == current })
        else { return }
        let step = forward ? 1 : items.count - 1
        await focusTab(items[(index + step) % items.count].id)
    }
}
