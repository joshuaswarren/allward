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

        let window = MainWindowController(model: model)
        mainWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        buildMenu()
        await model.openInitialSession()
        startControlSocket(for: model)
        await model.startSurfaceObservation(window: window)
        startConfigurationReload(at: configurationURL, initial: configuration, model: model)
        if let capturePath = Self.capturePath() {
            await runCapture(window: window, model: model, to: capturePath)
        } else {
            window.presentOnboardingIfNeeded()
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
        try? await Task.sleep(for: .seconds(1))
        do {
            try await WindowCapture.capture(window: nsWindow, model: model, to: url)
            let items = nsWindow.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
            print("captured \(url.path)")
            print("toolbar items: \(items.joined(separator: ", "))")
            print("panes: \(model.topology.panes.count) rooms: \(model.rooms.count)")
            print("tabs: \(model.tabStripItems().count) layout: \(String(describing: model.currentLayout()))")
            print(window.layoutReport())
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
    private static func captureExercise() -> [String] {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--exercise"),
            arguments.index(after: index) < arguments.endIndex
        else { return [] }
        return arguments[arguments.index(after: index)]
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func perform(_ step: String, window: MainWindowController, model: AppModel) async {
        defer {
            print(
                "step \(step): panes=\(model.topology.panes.count) "
                    + "tabs=\(model.tabStripItems().count) "
                    + "note=\(model.lastActionMessage ?? "none")")
        }
        switch step {
        case "split-right": await model.splitFocusedPane(.horizontal)
        case "split-down": await model.splitFocusedPane(.vertical)
        case "new-tab": await model.newTab()
        case "board":
            window.presentBoard()
            await waitForSurface(window)
        case "digest":
            window.presentDigest()
            await waitForSurface(window)
        case "palette":
            window.presentCommandPalette()
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
    /// board, router, palette and onboarding advertise is defined exactly once,
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
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Split right", #selector(splitRight(_:)), Shortcut.splitRight)
        add(viewMenu, "Split down", #selector(splitDown(_:)), Shortcut.splitDown)
        viewMenu.addItem(.separator())
        add(viewMenu, "Focus pane left", #selector(focusLeft(_:)), Shortcut.focusLeft)
        add(viewMenu, "Focus pane right", #selector(focusRight(_:)), Shortcut.focusRight)
        add(viewMenu, "Focus pane up", #selector(focusUp(_:)), Shortcut.focusUp)
        add(viewMenu, "Focus pane down", #selector(focusDown(_:)), Shortcut.focusDown)
        viewMenu.addItem(.separator())
        add(viewMenu, "Next tab", #selector(nextTab(_:)), Shortcut.nextTab)
        add(viewMenu, "Previous tab", #selector(previousTab(_:)), Shortcut.previousTab)
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

        NSApp.mainMenu = main
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

    @objc public func connectSSH(_ sender: Any?) { mainWindow?.presentHostPicker() }
    @objc public func showBoard(_ sender: Any?) { mainWindow?.presentBoard() }
    @objc public func focusRouter(_ sender: Any?) { mainWindow?.presentBoard() }
    @objc public func showDigest(_ sender: Any?) { mainWindow?.presentDigest() }
    @objc public func showCommandPalette(_ sender: Any?) { mainWindow?.presentCommandPalette() }
    @objc public func showRoomSwitcher(_ sender: Any?) { mainWindow?.presentRoomSwitcher() }
    @objc public func teleport(_ sender: Any?) { Task { await model.teleportToRoutedDestination() } }
    @objc public func showSettings(_ sender: Any?) { mainWindow?.presentSettings() }
    @objc public func showDiagnostics(_ sender: Any?) { mainWindow?.presentDiagnostics() }
}
