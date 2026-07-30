import AllwardCore
import AllwardTerminal

extension ControlService {
    public func readScreen(target: Target) async -> ScreenRead? {
        guard let pane = target.pane, await registry.target(for: pane) == target else { return nil }
        return await readScreen(pane: pane)
    }

    public func readHistory(target: Target, lines: Int) async -> [String]? {
        guard let pane = target.pane, await registry.target(for: pane) == target else { return nil }
        return await readHistory(pane: pane, lines: lines)
    }

    public func lastCommand(target: Target) async -> CommandRegion? {
        guard let pane = target.pane, await registry.target(for: pane) == target else { return nil }
        return await lastCommand(pane: pane)
    }

    public func exitCode(target: Target) async -> Int32? {
        guard let pane = target.pane, await registry.target(for: pane) == target else { return nil }
        return await exitCode(pane: pane)
    }
}
