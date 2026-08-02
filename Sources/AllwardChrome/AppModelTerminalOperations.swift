import AllwardConfig
import AllwardCore
import AllwardTerminal
import AppKit

/// The operations every Mac terminal is expected to have.
///
/// These are conventions, not features: a terminal that cannot copy with
/// Command-C or jump to a tab with Command-2 is broken from the first minute,
/// however good the rest of it is.
@MainActor
extension AppModel {
    // MARK: Clipboard

    public func copySelection() async {
        guard let pane = focusedPane,
            let text = await control.session(for: pane)?.selectedText(),
            !text.isEmpty
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func pasteFromClipboard() {
        guard let pane = focusedPane, let view = paneView(for: pane),
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        view.paste(text)
    }

    public func selectAllInFocusedPane() async {
        guard let pane = focusedPane, let snapshot = paneView(for: pane)?.snapshot,
            let first = snapshot.rowIDs.first, let last = snapshot.rowIDs.last
        else { return }
        let selection = Selection(
            start: SelectionAnchor(line: first, graphemeOffset: 0),
            end: SelectionAnchor(line: last, graphemeOffset: snapshot.geometry.columns),
            mode: .stream)
        await control.session(for: pane)?.setSelection(selection)
    }

    // MARK: Screen

    /// Clear is the shell's job, not the emulator's: sending the same key the
    /// terminal would keeps the shell's own idea of the screen in step.
    public func clearFocusedScreen() {
        guard let pane = focusedPane, let view = paneView(for: pane) else { return }
        view.sendControl("l")
    }

    // MARK: Font size

    public func adjustFontSize(by delta: Double) async {
        var updated = configuration
        updated.terminal.fontSize = min(72, max(6, updated.terminal.fontSize + delta))
        await applyTerminalConfiguration(updated)
    }

    public func resetFontSize() async {
        var updated = configuration
        updated.terminal.fontSize = TerminalConfiguration().fontSize
        await applyTerminalConfiguration(updated)
    }

    private func applyTerminalConfiguration(_ updated: Configuration) async {
        if let failure = configurationLoadFailure {
            lastActionMessage = "The font size cannot be saved: \(failure)"
            return
        }
        do {
            let written = try await updated.writeOffMainThread(to: AllwardPaths.configurationFile())
            await applyConfiguration(written)
        } catch {
            lastActionMessage = "The font size could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Scrolling

    public func scrollFocusedPane(byRows rows: Int) async {
        guard let pane = focusedPane else { return }
        await control.session(for: pane)?.scroll(byRows: rows)
        await refreshFocusedPane()
    }

    public func scrollFocusedPane(toTop: Bool) async {
        guard let pane = focusedPane, let snapshot = paneView(for: pane)?.snapshot else { return }
        let distance = snapshot.scrollbackCount + snapshot.geometry.rows
        await scrollFocusedPane(byRows: toTop ? distance : -distance)
    }

    /// Jump between shell prompts, which the OSC 133 marks already record.
    /// Without them this would be a guess; with them it is exact.
    public func jumpToPrompt(previous: Bool) async {
        guard let pane = focusedPane, let snapshot = paneView(for: pane)?.snapshot else { return }
        // A prompt is recorded as a line identity, so it has to be mapped back
        // onto the rows currently in view.
        var rows: [Int] = []
        for region in snapshot.commandRegions {
            if let row = snapshot.rowIDs.firstIndex(of: region.promptLine) { rows.append(row) }
        }
        rows.sort()
        guard !rows.isEmpty else {
            lastActionMessage = "No shell prompts are marked in this pane yet."
            return
        }
        let cursor = snapshot.cursor.row
        let target =
            previous
            ? rows.last(where: { $0 < cursor }) ?? rows.first
            : rows.first(where: { $0 > cursor }) ?? rows.last
        guard let target else { return }
        await scrollFocusedPane(byRows: cursor - target)
    }

    private func refreshFocusedPane() async {
        guard let pane = focusedPane, let session = await control.session(for: pane),
            let view = paneView(for: pane)
        else { return }
        view.apply(await session.snapshot(), focused: true)
    }

    // MARK: Tabs

    /// Cycle panes in layout order, which is what Command-[ and Command-]
    /// do in every terminal that has splits.
    public func focusAdjacentPane(forward: Bool) async {
        guard let layout = currentLayout() else { return }
        let panes = layout.leaves
        guard panes.count > 1, let current = focusedPane,
            let index = panes.firstIndex(of: current)
        else { return }
        let step = forward ? 1 : panes.count - 1
        await focus(panes[(index + step) % panes.count])
    }

    /// Re-reads the configuration file on demand rather than waiting for the
    /// watcher, which is what Shift-Command-Comma is for.
    public func reloadConfigurationFromDisk() async {
        do {
            let loaded = try await Configuration.loadOffMainThread(from: AllwardPaths.configurationFile())
            await applyConfiguration(loaded)
        } catch {
            lastActionMessage = "The configuration could not be reloaded: \(error.localizedDescription)"
        }
    }

    /// Command-1 through Command-8 pick that tab; Command-9 picks the last,
    /// matching Safari, Chrome, Terminal.app, iTerm and Ghostty.
    public func selectTab(at index: Int) async {
        let order = tabOrder()
        guard !order.isEmpty else { return }
        let target = index >= 9 ? order.count - 1 : index - 1
        guard target >= 0, target < order.count else { return }
        await focusTab(order[target])
    }
}
