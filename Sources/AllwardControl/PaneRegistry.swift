import AllwardCore
import AllwardMultiplexer
import AllwardRemote
import Foundation

public struct PaneTopology: Codable, Hashable, Sendable {
    public var id: PaneID
    public var session: SessionID
    public var target: Target
    public var destination: RemoteDestination
    public var contentRoute: AdapterContentRoute?
}

public struct TabTopology: Codable, Hashable, Sendable {
    public var id: TabID
    public var tree: SplitTree?
    public var focusedPane: PaneID?
}

public struct WindowTopology: Codable, Hashable, Sendable {
    public var id: WindowID
    public var room: RoomID
    public var tabs: [TabTopology]
    public var focusedTab: TabID?
}

public struct TopologySnapshot: Codable, Hashable, Sendable {
    public var generation: Generation
    public var windows: [WindowTopology]
    public var panes: [PaneTopology]

    public init(generation: Generation, windows: [WindowTopology], panes: [PaneTopology]) {
        self.generation = generation
        self.windows = windows
        self.panes = panes
    }
}

struct RegistryChange: Sendable { var before: Generation; var after: Generation }
struct RemovedPane: Sendable { var session: Session; var change: RegistryChange }
struct RemovedTab: Sendable {
    var paneIDs: [PaneID]
    var sessions: [Session]
    var change: RegistryChange
}

actor PaneRegistry {
    private struct PaneEntry {
        var session: Session
        var target: Target
        var destination: RemoteDestination
        var contentRoute: AdapterContentRoute?
    }
    private struct TabEntry { var tree: SplitTree?; var focusedPane: PaneID? }

    /// Every live session, for state that has to reach all of them at once -
    /// the theme colours a program can query, for instance.
    var allSessions: [Session] { panes.values.map(\.session) }
    private struct WindowEntry {
        var room: RoomID
        var tabOrder: [TabID]
        var tabs: [TabID: TabEntry]
        var focusedTab: TabID?
    }

    private var current: Generation = .initial
    private var windowOrder: [WindowID] = []
    private var windows: [WindowID: WindowEntry] = [:]
    private var panes: [PaneID: PaneEntry] = [:]

    var generation: Generation { current }

    func snapshot() -> TopologySnapshot {
        var paneSnapshots: [PaneTopology] = []
        let windowSnapshots = windowOrder.compactMap { windowID -> WindowTopology? in
            guard let window = windows[windowID] else { return nil }
            let tabs = window.tabOrder.compactMap { tabID -> TabTopology? in
                guard let tab = window.tabs[tabID] else { return nil }
                for paneID in tab.tree?.leaves ?? [] {
                    guard let pane = panes[paneID], let sessionID = pane.target.session else { continue }
                    paneSnapshots.append(
                        PaneTopology(
                            id: paneID,
                            session: sessionID,
                            target: pane.target,
                            destination: pane.destination,
                            contentRoute: pane.contentRoute
                        )
                    )
                }
                return TabTopology(id: tabID, tree: tab.tree, focusedPane: tab.focusedPane)
            }
            return WindowTopology(
                id: windowID,
                room: window.room,
                tabs: tabs,
                focusedTab: window.focusedTab
            )
        }
        return TopologySnapshot(generation: current, windows: windowSnapshots, panes: paneSnapshots)
    }

    func rejection(for target: Target, expectedGeneration: Generation) -> ControlRejection? {
        if let failure = generationFailure(expectedGeneration) { return failure }
        if let paneID = target.pane {
            guard let pane = panes[paneID] else { return .paneNotFound(paneID) }
            guard pane.target == target else { return .targetMismatch(expected: pane.target, actual: target) }
        }
        return nil
    }

    func createTab(
        window windowID: WindowID,
        tab tabID: TabID,
        room: RoomID,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        var window = windows[windowID] ?? newWindow(room: room)
        guard window.room == room else {
            return .failure(.targetMismatch(expected: Target(room: window.room), actual: Target(room: room)))
        }
        guard window.tabs[tabID] == nil else { return .failure(.unsupported("Tab already exists")) }
        if windows[windowID] == nil { windowOrder.append(windowID) }
        window.tabs[tabID] = TabEntry(tree: nil, focusedPane: nil)
        window.tabOrder.append(tabID)
        window.focusedTab = tabID
        windows[windowID] = window
        return .success(advance())
    }

    func insertFirstPane(
        _ paneID: PaneID,
        session: Session,
        target: Target,
        destination: RemoteDestination,
        contentRoute: AdapterContentRoute?,
        window windowID: WindowID,
        tab tabID: TabID,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard panes[paneID] == nil else { return .failure(.unsupported("Pane already exists")) }
        guard target.pane == paneID, target.session != nil else {
            return .failure(.targetMismatch(expected: Target(room: target.room, pane: paneID), actual: target))
        }
        var window = windows[windowID] ?? newWindow(room: target.room)
        guard window.room == target.room else {
            return .failure(.targetMismatch(expected: Target(room: window.room), actual: target))
        }
        var tab = window.tabs[tabID] ?? TabEntry(tree: nil, focusedPane: nil)
        guard tab.tree == nil else { return .failure(.unsupported("Tab already has a pane")) }
        if windows[windowID] == nil { windowOrder.append(windowID) }
        if window.tabs[tabID] == nil { window.tabOrder.append(tabID) }
        tab.tree = .leaf(paneID)
        tab.focusedPane = paneID
        window.tabs[tabID] = tab
        window.focusedTab = tabID
        windows[windowID] = window
        panes[paneID] = PaneEntry(
            session: session,
            target: target,
            destination: destination,
            contentRoute: contentRoute
        )
        return .success(advance())
    }

    func splitPane(
        existingPane: PaneID,
        newPane: PaneID,
        session: Session,
        target: Target,
        destination: RemoteDestination,
        contentRoute: AdapterContentRoute?,
        orientation: SplitOrientation,
        ratio: Double,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard panes[existingPane] != nil else { return .failure(.paneNotFound(existingPane)) }
        guard panes[newPane] == nil else { return .failure(.unsupported("Pane already exists")) }
        guard let position = location(of: existingPane), var window = windows[position.window],
              var tab = window.tabs[position.tab], let tree = tab.tree
        else { return .failure(.paneNotFound(existingPane)) }
        do {
            tab.tree = try tree.splitting(
                pane: existingPane,
                newPane: newPane,
                orientation: orientation,
                ratio: ratio
            )
        } catch {
            return .failure(.unsupported("Invalid split"))
        }
        tab.focusedPane = newPane
        window.tabs[position.tab] = tab
        window.focusedTab = position.tab
        windows[position.window] = window
        panes[newPane] = PaneEntry(
            session: session,
            target: target,
            destination: destination,
            contentRoute: contentRoute
        )
        return .success(advance())
    }

    func closePane(
        _ paneID: PaneID,
        expectedGeneration: Generation
    ) -> Result<RemovedPane, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard let entry = panes[paneID], let position = location(of: paneID),
              var window = windows[position.window], var tab = window.tabs[position.tab],
              let tree = tab.tree
        else { return .failure(.paneNotFound(paneID)) }
        let closedIndex = tree.leaves.firstIndex(of: paneID) ?? 0
        let wasFocused = tab.focusedPane == paneID
        do { tab.tree = try tree.closing(pane: paneID) } catch {
            return .failure(.paneNotFound(paneID))
        }
        if wasFocused {
            let remaining = tab.tree?.leaves ?? []
            tab.focusedPane = remaining.isEmpty ? nil : remaining[min(closedIndex, remaining.count - 1)]
        }
        // A tab whose last pane closed is finished: every terminal collapses
        // the tab rather than leaving an empty frame behind.
        if tab.tree == nil || tab.tree?.leaves.isEmpty == true {
            window.tabs.removeValue(forKey: position.tab)
            window.tabOrder.removeAll { $0 == position.tab }
            window.focusedTab = window.tabOrder.last
        } else {
            window.tabs[position.tab] = tab
        }
        windows[position.window] = window
        panes.removeValue(forKey: paneID)
        return .success(RemovedPane(session: entry.session, change: advance()))
    }

    func focusPane(
        _ paneID: PaneID,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard let position = location(of: paneID), var window = windows[position.window],
              var tab = window.tabs[position.tab]
        else { return .failure(.paneNotFound(paneID)) }
        tab.focusedPane = paneID
        window.tabs[position.tab] = tab
        window.focusedTab = position.tab
        windows[position.window] = window
        return .success(advance())
    }

    func moveFocus(
        from paneID: PaneID,
        direction: FocusDirection,
        expectedGeneration: Generation
    ) -> Result<(PaneID, RegistryChange), ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard let position = location(of: paneID), var window = windows[position.window],
              var tab = window.tabs[position.tab], let tree = tab.tree
        else { return .failure(.paneNotFound(paneID)) }
        guard let next = tree.focus(from: paneID, moving: direction) else {
            return .failure(.unsupported("No pane in that direction"))
        }
        tab.focusedPane = next
        window.tabs[position.tab] = tab
        windows[position.window] = window
        return .success((next, advance()))
    }

    func closeTab(
        _ tabID: TabID,
        window windowID: WindowID,
        target: Target,
        expectedGeneration: Generation
    ) -> Result<RemovedTab, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard var window = windows[windowID], let tab = window.tabs[tabID] else {
            return .failure(.tabNotFound(tabID))
        }
        guard window.room == target.room else {
            return .failure(
                .targetMismatch(expected: Target(room: window.room), actual: target)
            )
        }
        if let paneID = target.pane, tab.tree?.leaves.contains(paneID) != true {
            return .failure(.unsupported("Target pane does not belong to the tab"))
        }
        let closingIndex = window.tabOrder.firstIndex(of: tabID) ?? 0
        let wasFocused = window.focusedTab == tabID
        let paneIDs = tab.tree?.leaves ?? []
        let sessions = paneIDs.compactMap { panes.removeValue(forKey: $0)?.session }
        window.tabs.removeValue(forKey: tabID)
        window.tabOrder.removeAll { $0 == tabID }
        if wasFocused {
            window.focusedTab = window.tabOrder.isEmpty
                ? nil
                : window.tabOrder[min(closingIndex, window.tabOrder.count - 1)]
        }
        windows[windowID] = window
        return .success(RemovedTab(paneIDs: paneIDs, sessions: sessions, change: advance()))
    }

    func setRoom(
        window windowID: WindowID,
        room: RoomID,
        target: Target,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard var window = windows[windowID] else { return .failure(.windowNotFound(windowID)) }
        guard window.room == target.room else {
            return .failure(
                .targetMismatch(expected: Target(room: window.room), actual: target)
            )
        }
        if let paneID = target.pane, location(of: paneID)?.window != windowID {
            return .failure(.unsupported("Target pane does not belong to the window"))
        }
        window.room = room
        for tabID in window.tabOrder {
            for paneID in window.tabs[tabID]?.tree?.leaves ?? [] { panes[paneID]?.target.room = room }
        }
        windows[windowID] = window
        return .success(advance())
    }

    func touchPane(
        _ paneID: PaneID,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard panes[paneID] != nil else { return .failure(.paneNotFound(paneID)) }
        return .success(advance())
    }

    func touch(expectedGeneration: Generation) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        return .success(advance())
    }

    /// Applies a new divider ratio to the tab that owns `paneID`. Split layout
    /// is Allward-owned, so this never reaches an adapter.
    func resizeDivider(
        containing paneID: PaneID,
        path: SplitPath,
        ratio: Double,
        expectedGeneration: Generation
    ) -> Result<RegistryChange, ControlRejection> {
        if let failure = generationFailure(expectedGeneration) { return .failure(failure) }
        guard let position = location(of: paneID) else { return .failure(.paneNotFound(paneID)) }
        guard var window = windows[position.window], var tab = window.tabs[position.tab],
            let tree = tab.tree
        else { return .failure(.paneNotFound(paneID)) }
        do {
            tab.tree = try tree.resizingDivider(at: path, to: ratio)
        } catch {
            return .failure(.unsupported("The divider could not be resized"))
        }
        window.tabs[position.tab] = tab
        windows[position.window] = window
        return .success(advance())
    }

    func session(for paneID: PaneID) -> Session? { panes[paneID]?.session }
    func target(for paneID: PaneID) -> Target? { panes[paneID]?.target }

    private func newWindow(room: RoomID) -> WindowEntry {
        WindowEntry(room: room, tabOrder: [], tabs: [:], focusedTab: nil)
    }

    private func generationFailure(_ expected: Generation) -> ControlRejection? {
        expected == current ? nil : .staleGeneration(expected: expected, actual: current)
    }

    private func location(of paneID: PaneID) -> (window: WindowID, tab: TabID)? {
        for windowID in windowOrder {
            guard let window = windows[windowID] else { continue }
            for tabID in window.tabOrder where window.tabs[tabID]?.tree?.leaves.contains(paneID) == true {
                return (windowID, tabID)
            }
        }
        return nil
    }

    private func advance() -> RegistryChange {
        let before = current
        current = current.next
        return RegistryChange(before: before, after: current)
    }
}
