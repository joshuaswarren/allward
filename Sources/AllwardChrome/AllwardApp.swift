import AllwardConfig
import AllwardControl
import AllwardCore
import AllwardDesign
import AllwardHerdr
import AllwardMultiplexer
import AllwardRooms
import AllwardSurfaces
import AppKit
import SwiftUI

/// The application object. It owns the model, the main window, the app control
/// socket, and the menu; it does no terminal or surface work itself.
@MainActor
public final class AllwardAppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var model: AppModel!
    private var mainWindow: MainWindowController?
    private var socketHost: ControlSocketHost?
    private var configurationReloader: ConfigurationReloader?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await bootstrap() }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        socketHost?.stop()
    }

    private func bootstrap() async {
        let configurationURL = AllwardPaths.configurationFile()
        let configuration = Self.loadOrSeedConfiguration(at: configurationURL)

        let roomStore = RoomStore(rooms: configuration.rooms)
        let surfaces = SurfaceStore(clock: SystemClock())
        let adapter = Self.makeAdapter(for: configuration)

        let model = AppModel(
            configuration: configuration, roomStore: roomStore, surfaces: surfaces,
            adapter: adapter)
        self.model = model
        await model.loadRooms()

        // The first window is the first tab. Creating it up front gives the
        // initial shell a real size to start at; reconciliation adopts it.
        let firstTab = TabID()
        let window = MainWindowController(model: model, tab: firstTab)
        mainWindow = window
        model.attach(window: window)
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        buildMenu()
        // Observation first: it hands the model the window, which is how the
        // initial shell learns its real size before it prints a prompt.
        await model.startSurfaceObservation(window: window)
        await model.openInitialSession(tab: firstTab)
        startControlSocket(for: model)
        startConfigurationReload(at: configurationURL, initial: configuration, model: model)
        if let capturePath = Self.capturePath() {
            await runCapture(window: window, model: model, to: capturePath)
        }
    }

    private func startControlSocket(for model: AppModel) {
        guard model.configuration.mcpEnabled else { return }
        let host = ControlSocketHost()
        socketHost = host
        do {
            try host.start(handler: model.control, at: ControlSocketHost.defaultPath())
        } catch {
            NSLog("Allward: the app control socket could not start: \(error)")
        }
    }


    /// A first run must land in a usable app, so a missing configuration file is
    /// seeded with the validated defaults rather than treated as an error.
    private static func loadOrSeedConfiguration(at url: URL) -> Configuration {
        if let existing = try? Configuration.load(from: url) { return existing }
        let defaults = Configuration()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? defaults.write(to: url)) ?? defaults
    }

    /// Live reload is file-event driven; nothing polls the configuration path.
    private func startConfigurationReload(
        at url: URL, initial: Configuration, model: AppModel
    ) {
        let reloader = ConfigurationReloader(url: url, initial: initial)
        configurationReloader = reloader
        Task {
            try? await reloader.start()
            for await event in await reloader.events() {
                guard case let .configuration(configuration) = event else { continue }
                await model.applyConfiguration(configuration)
            }
        }
    }


    /// herdr is optional. It is constructed only when a Room actually declares
    /// an adapter server, and its absence is normal capability absence.
    private static func makeAdapter(for configuration: Configuration) -> any MultiplexerAdapter {
        let adapterHosts = configuration.rooms
            .filter { !$0.adapterServers.isEmpty }
            .flatMap { $0.hostAliases }
        guard let endpoint = HerdrProcessExecutor.endpoint(host: adapterHosts.first) else {
            return NoMultiplexerAdapter()
        }
        return HerdrAdapter(client: HerdrProcessExecutor.makeClient(for: endpoint))
    }


    /// `--capture <path>` renders the live window once and exits. It exists so
    /// on-screen behaviour can be evidenced without a screen-recording grant.
    private static func capturePath() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture"),
            arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: index)])
    }

    /// `--type <command>` writes real keystrokes into the focused pane before
    /// the capture, so the evidence covers the input path and not just render.
    private static func captureCommand() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--type"),
            arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: index)]
    }

    private func runCapture(window: MainWindowController, model: AppModel, to url: URL) async {
        guard let nsWindow = window.window else { exit(2) }
        // Wait for the first pane to exist rather than guessing a duration, so
        // a loaded machine cannot produce a capture of a half-started app.
        for _ in 0..<60 where model.focusedPane == nil {
            try? await Task.sleep(for: .milliseconds(250))
            await model.refreshTopology()
        }
        guard model.focusedPane != nil else {
            FileHandle.standardError.write(Data("capture failed: no pane started\n".utf8))
            exit(4)
        }
        // Let the shell produce its first prompt so the capture shows real
        // session content rather than an empty grid.
        try? await Task.sleep(for: .seconds(2))
        await model.refreshTopology()
        print("exercise steps: \(Self.captureExercise())")
        for step in Self.captureExercise() {
            await perform(step, window: window, model: model)
            try? await Task.sleep(for: .milliseconds(900))
        }
        if let command = Self.captureCommand(), let pane = model.focusedPane {
            let session = await model.control.session(for: pane)
            await session?.write(Array((command + "\r").utf8))
            try? await Task.sleep(for: .seconds(3))
        }
        // Steps that need the command's output to exist, such as searching it.
        for step in Self.captureExercise(flag: "--then") {
            await perform(step, window: window, model: model)
            try? await Task.sleep(for: .milliseconds(900))
        }
        try? await Task.sleep(for: .seconds(1))
        do {
            try await WindowCapture.capture(window: nsWindow, model: model, to: url)
            let items = nsWindow.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
            print("captured \(url.path)")
            print("toolbar items: \(items.joined(separator: ", "))")
            print("panes: \(model.topology.panes.count) rooms: \(model.rooms.count)")
            print("tabs: \(model.tabOrder().count) layout: \(String(describing: model.currentLayout()))")
            print(window.layoutReport())
            print("menu: \(Self.menuReport())")
            print("grids: \(model.gridReport())")
            print("rows:\n\(model.rowDump())")
            print("focusedPane: \(model.focusedPane?.shortLabel ?? "none") focusedTab: \(model.focusedTab?.shortLabel ?? "none") focusedWindow: \(model.focusedWindow?.shortLabel ?? "none")")
            if let message = model.lastActionMessage { print("note: \(message)") }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(3)
        }
    }


    /// `--exercise a,b,c` drives real app operations before the capture so the
    /// evidence covers splits, tabs, and summoned surfaces rather than only the
    /// first launch state.
    private static func captureExercise(flag: String = "--exercise") -> [String] {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
            arguments.index(after: index) < arguments.endIndex
        else { return [] }
        return arguments[arguments.index(after: index)]
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func perform(_ step: String, window: MainWindowController, model: AppModel) async {
        defer {
            print(
                "step \(step): panes=\(model.topology.panes.count) "
                    + "focusedTab=\(model.focusedTab?.shortLabel ?? "none") "
                    + "firstResponder=\(window.window?.firstResponder.map { "\(type(of: $0))" } ?? "none") "
                    + "surface=\(window.presentedSurface.map { "\($0)" } ?? "none") "
                    + "gridBg=\(String(format: "%.2f", model.terminalTheme.defaultBackground.relativeLuminance)) "
                    + "matches=\(model.searchMatchCount) "
                    + "tabs=\(model.tabOrder().count) "
                    + "note=\(model.lastActionMessage ?? "none")")
        }
        switch step {
        case "split-right": await model.splitFocusedPane(.horizontal)
        case "split-down": await model.splitFocusedPane(.vertical)
        case "new-tab": await model.newTab()
        case "find":
            window.presentFind()
            await waitForSurface(window)
        case let step where step.hasPrefix("search-"):
            await model.search(for: String(step.dropFirst(7)))
        case "wait":
            try? await Task.sleep(for: .seconds(3))
            await model.refreshTopology()
        case "escape":
            // Focus has to settle first: SwiftUI installs the key view that
            // swallowed Escape a moment after the card appears, so firing
            // immediately tests the only state in which the bug does not exist.
            try? await Task.sleep(for: .milliseconds(600))
            sendEscapeKey(to: window)
            try? await Task.sleep(for: .milliseconds(400))
        case let step where step.hasPrefix("theme-"):
            await model.applySettingsUpdate(.selectTheme(themeID: String(step.dropFirst(6))))
        case let step where step.hasPrefix("tab-"):
            await model.selectTab(at: Int(step.dropFirst(4)) ?? 1)
        case "board":
            window.presentBoard()
            await waitForSurface(window)
        case "digest":
            window.presentDigest()
            await waitForSurface(window)
        case "palette":
            window.presentCommandPalette()
            await waitForSurface(window)
        case let step where step.hasPrefix("settings-"):
            // A settings section can only be verified if the harness can reach
            // it; three broken controls sat on sections nothing ever opened.
            guard let tab = SettingsTab(rawValue: String(step.dropFirst(9))) else { break }
            model.selectedSettingsTab = tab
            window.presentSettings()
            await waitForSurface(window)
        case "settings":
            window.presentSettings()
            await waitForSurface(window)
        case "rooms":
            window.presentRoomSwitcher()
            await waitForSurface(window)
        default: break
        }
    }

    /// Posts Escape the way the keyboard does, so the test exercises key
    /// routing rather than the handler it is supposed to reach.
    /// An Escape delivered to the window, after focus has settled.
    ///
    /// Escape was reported broken three times while this harness passed. Two
    /// reasons, both fixed here. It called `cancelOperation` directly, which
    /// proves a method runs rather than that a key reaches it. And it fired the
    /// instant the surface appeared, before SwiftUI installs the key view that
    /// was eating the key - so it tested the one moment the bug is absent.
    ///
    /// Under `--capture` the app is never key (`active=false`), so a posted
    /// CGEvent is discarded by the window server and cannot be used. The event
    /// goes to `NSWindow.sendEvent`, which is where a real key enters the
    /// window and the deepest point the application controls.
    private func sendEscapeKey(to window: MainWindowController) {
        guard let nsWindow = window.window,
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nsWindow.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)
        else { return }
        print("escape into: \(type(of: nsWindow)) responder="
            + "\(nsWindow.firstResponder.map { "\(type(of: $0))" } ?? "none")")
        nsWindow.sendEvent(down)
    }

    /// A surface presents through an async projection, so a capture that fires
    /// immediately photographs the window before the surface exists. Report the
    /// wait rather than sleeping blindly.
    private func waitForSurface(_ window: MainWindowController) async {
        for _ in 0..<40 {
            if window.presentedSurface != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        print("step warning: no surface presented after 2s")
    }

    // MARK: Menu

    /// The menu is the canonical key-equivalent registry. Every shortcut the
    /// board, router and palette advertise is defined exactly once,
    /// here, so they can never drift from what actually works.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Allward", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(showSettings(_:)), Shortcut.settings)
        add(
            appMenu, "Reload configuration", #selector(reloadConfiguration(_:)),
            Shortcut.reloadConfiguration)
        add(appMenu, "Diagnostics", #selector(showDiagnostics(_:)), KeyChord("/", [.command, .shift]))
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Allward", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Quit Allward", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "New tab", #selector(newTab(_:)), Shortcut.newTab)
        add(fileMenu, "New pane in this tab", #selector(newLocalTerminal(_:)), Shortcut.newLocalTerminal)
        add(fileMenu, "New window", #selector(newWindow(_:)), Shortcut.newWindow)
        add(fileMenu, "Connect to SSH host…", #selector(connectSSH(_:)), Shortcut.connectSSH)
        fileMenu.addItem(.separator())
        add(fileMenu, "Close pane", #selector(closePane(_:)), Shortcut.closePane)
        add(fileMenu, "Close tab", #selector(closeTab(_:)), Shortcut.closeTab)
        add(
            fileMenu, "Close window", #selector(NSWindow.performClose(_:)),
            Shortcut.closeWindow)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // An Edit menu is not decoration: without it Command-C, Command-V and
        // Command-A do nothing, which is the first thing anyone tries.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(editMenu, "Copy", #selector(copySelection(_:)), Shortcut.copy)
        add(editMenu, "Paste", #selector(pasteText(_:)), Shortcut.paste)
        add(editMenu, "Select all", #selector(selectAllText(_:)), Shortcut.selectAll)
        editMenu.addItem(.separator())
        add(editMenu, "Find…", #selector(showFind(_:)), Shortcut.find)
        add(editMenu, "Find next", #selector(findNext(_:)), Shortcut.findNext)
        add(editMenu, "Find previous", #selector(findPrevious(_:)), Shortcut.findPrevious)
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(
            viewMenu, "Toggle full screen", #selector(NSWindow.toggleFullScreen(_:)),
            Shortcut.toggleFullScreen)
        viewMenu.addItem(.separator())
        add(viewMenu, "Clear screen", #selector(clearScreen(_:)), Shortcut.clearScreen)
        viewMenu.addItem(.separator())
        add(viewMenu, "Bigger text", #selector(increaseFontSize(_:)), Shortcut.increaseFontSize)
        add(viewMenu, "Smaller text", #selector(decreaseFontSize(_:)), Shortcut.decreaseFontSize)
        add(viewMenu, "Actual size", #selector(resetFontSize(_:)), Shortcut.resetFontSize)
        viewMenu.addItem(.separator())
        add(viewMenu, "Scroll to top", #selector(scrollToTop(_:)), Shortcut.scrollToTop)
        add(viewMenu, "Scroll to bottom", #selector(scrollToBottom(_:)), Shortcut.scrollToBottom)
        add(viewMenu, "Page up", #selector(scrollPageUp(_:)), Shortcut.scrollPageUp)
        add(viewMenu, "Page down", #selector(scrollPageDown(_:)), Shortcut.scrollPageDown)
        viewMenu.addItem(.separator())
        add(viewMenu, "Previous prompt", #selector(previousPrompt(_:)), Shortcut.previousPrompt)
        add(viewMenu, "Next prompt", #selector(nextPrompt(_:)), Shortcut.nextPrompt)
        viewMenu.addItem(.separator())
        add(viewMenu, "Split right", #selector(splitRight(_:)), Shortcut.splitRight)
        add(viewMenu, "Split down", #selector(splitDown(_:)), Shortcut.splitDown)
        viewMenu.addItem(.separator())
        add(viewMenu, "Focus pane left", #selector(focusLeft(_:)), Shortcut.focusLeft)
        add(viewMenu, "Focus pane right", #selector(focusRight(_:)), Shortcut.focusRight)
        add(viewMenu, "Focus pane up", #selector(focusUp(_:)), Shortcut.focusUp)
        add(viewMenu, "Focus pane down", #selector(focusDown(_:)), Shortcut.focusDown)
        add(viewMenu, "Previous pane", #selector(previousSplit(_:)), Shortcut.previousSplit)
        add(viewMenu, "Next pane", #selector(nextSplit(_:)), Shortcut.nextSplit)
        viewMenu.addItem(.separator())
        add(viewMenu, "Next tab", #selector(nextTab(_:)), Shortcut.nextTab)
        add(viewMenu, "Previous tab", #selector(previousTab(_:)), Shortcut.previousTab)
        add(viewMenu, "Next tab ", #selector(nextTab(_:)), Shortcut.nextTabBracket)
        add(viewMenu, "Previous tab ", #selector(previousTab(_:)), Shortcut.previousTabBracket)
        for index in 1 ... 9 {
            let title = index == 9 ? "Last tab" : "Tab \(index)"
            add(viewMenu, title, #selector(selectNumberedTab(_:)), Shortcut.selectTab(index))
            viewMenu.items.last?.tag = index
        }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let workItem = NSMenuItem()
        let workMenu = NSMenu(title: "Work")
        add(workMenu, "Session board", #selector(showBoard(_:)), Shortcut.board)
        add(workMenu, "Attention router", #selector(focusRouter(_:)), Shortcut.router)
        add(workMenu, "Re-entry digest", #selector(showDigest(_:)), Shortcut.digest)
        add(workMenu, "Command palette", #selector(showCommandPalette(_:)), Shortcut.palette)
        workMenu.addItem(.separator())
        add(workMenu, "Switch Room…", #selector(showRoomSwitcher(_:)), Shortcut.rooms)
        add(workMenu, "Teleport to destination", #selector(teleport(_:)), Shortcut.teleport)
        workItem.submenu = workMenu
        main.addItem(workItem)

        // AppKit fills a Window menu with Minimize, Zoom, the tab commands and
        // Merge All Windows. Without one, native tabbing loses half of what it
        // is for, which is what happened when this menu was missing.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// Every installed key equivalent, so a claim that a shortcut exists can be
    /// checked against the menu rather than against the registry that feeds it.
    static func menuReport() -> String {
        var lines: [String] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            let keys = submenu.items.compactMap { item -> String? in
                guard !item.keyEquivalent.isEmpty else { return nil }
                let chord = KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask)
                return "\(chord.display)=\(item.title)"
            }
            if !keys.isEmpty { lines.append("[\(submenu.title)] " + keys.joined(separator: " ")) }
        }
        return lines.joined(separator: " | ")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ chord: KeyChord) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: chord.key)
        item.keyEquivalentModifierMask = chord.modifiers
        item.target = self
        menu.addItem(item)
    }

    // MARK: Actions

    @objc public func newLocalTerminal(_ sender: Any?) { Task { await model.newLocalPane() } }
    @objc public func newTab(_ sender: Any?) { Task { await model.newTab() } }
    @objc public func closeTab(_ sender: Any?) {
        guard let tab = model.focusedTab else { return }
        Task { await model.closeTab(tab) }
    }
    @objc public func nextTab(_ sender: Any?) {
        Task { await model.selectAdjacentTab(forward: true) }
    }
    @objc public func previousTab(_ sender: Any?) {
        Task { await model.selectAdjacentTab(forward: false) }
    }
    @objc public func newWindow(_ sender: Any?) { Task { await model.openNewWindow() } }
    @objc public func closePane(_ sender: Any?) { Task { await model.closeFocusedPane() } }
    @objc public func splitRight(_ sender: Any?) {
        Task { await model.splitFocusedPane(.horizontal) }
    }
    @objc public func splitDown(_ sender: Any?) { Task { await model.splitFocusedPane(.vertical) } }
    @objc public func focusLeft(_ sender: Any?) { Task { await model.moveFocus(.left) } }
    @objc public func focusRight(_ sender: Any?) { Task { await model.moveFocus(.right) } }
    @objc public func focusUp(_ sender: Any?) { Task { await model.moveFocus(.up) } }
    @objc public func focusDown(_ sender: Any?) { Task { await model.moveFocus(.down) } }

    @objc public func connectSSH(_ sender: Any?) { model.keyWindowController?.presentHostPicker() }
    @objc public func showBoard(_ sender: Any?) { model.keyWindowController?.presentBoard() }
    @objc public func focusRouter(_ sender: Any?) { model.keyWindowController?.presentBoard() }
    @objc public func showDigest(_ sender: Any?) { model.keyWindowController?.presentDigest() }
    @objc public func showCommandPalette(_ sender: Any?) { model.keyWindowController?.presentCommandPalette() }
    @objc public func showRoomSwitcher(_ sender: Any?) { model.keyWindowController?.presentRoomSwitcher() }
    @objc public func teleport(_ sender: Any?) { Task { await model.teleportToRoutedDestination() } }
    @objc public func showSettings(_ sender: Any?) { model.keyWindowController?.presentSettings() }
    @objc public func showDiagnostics(_ sender: Any?) { model.keyWindowController?.presentDiagnostics() }

    // MARK: Conventional terminal commands

    @objc public func copySelection(_ sender: Any?) { Task { await model.copySelection() } }
    @objc public func pasteText(_ sender: Any?) { model.pasteFromClipboard() }
    @objc public func selectAllText(_ sender: Any?) {
        Task { await model.selectAllInFocusedPane() }
    }
    @objc public func clearScreen(_ sender: Any?) { model.clearFocusedScreen() }
    @objc public func increaseFontSize(_ sender: Any?) {
        Task { await model.adjustFontSize(by: 1) }
    }
    @objc public func decreaseFontSize(_ sender: Any?) {
        Task { await model.adjustFontSize(by: -1) }
    }
    @objc public func resetFontSize(_ sender: Any?) { Task { await model.resetFontSize() } }
    @objc public func scrollToTop(_ sender: Any?) {
        Task { await model.scrollFocusedPane(toTop: true) }
    }
    @objc public func scrollToBottom(_ sender: Any?) {
        Task { await model.scrollFocusedPane(toTop: false) }
    }
    @objc public func scrollPageUp(_ sender: Any?) {
        Task { await model.scrollFocusedPane(byRows: 20) }
    }
    @objc public func scrollPageDown(_ sender: Any?) {
        Task { await model.scrollFocusedPane(byRows: -20) }
    }
    @objc public func previousPrompt(_ sender: Any?) {
        Task { await model.jumpToPrompt(previous: true) }
    }
    @objc public func nextPrompt(_ sender: Any?) {
        Task { await model.jumpToPrompt(previous: false) }
    }
    @objc public func showFind(_ sender: Any?) { model.keyWindowController?.presentFind() }
    @objc public func findNext(_ sender: Any?) {
        Task { await model.stepSearchMatch(forward: true) }
    }
    @objc public func findPrevious(_ sender: Any?) {
        Task { await model.stepSearchMatch(forward: false) }
    }
    @objc public func previousSplit(_ sender: Any?) {
        Task { await model.focusAdjacentPane(forward: false) }
    }
    @objc public func nextSplit(_ sender: Any?) {
        Task { await model.focusAdjacentPane(forward: true) }
    }
    @objc public func reloadConfiguration(_ sender: Any?) {
        Task { await model.reloadConfigurationFromDisk() }
    }
    @objc public func selectNumberedTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        Task { [tag = item.tag] in await model.selectTab(at: tag) }
    }
}
