import AllwardChrome
import AllwardCore
import AllwardDesign
import AllwardRenderer
import AllwardTerminal
import AppKit
import SwiftUI

// Deterministic visual QA. It renders the real terminal scene through the same
// `SceneBuilder` the on-screen path uses, and the real SwiftUI surfaces through
// `ImageRenderer`, so a reviewer looks at production pixels rather than a mock.
//
// Usage: allward-qa <output-directory>

@MainActor
func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw QAError.encodingFailed(url.lastPathComponent)
    }
    try data.write(to: url)
}

enum QAError: Error { case encodingFailed(String) }

@MainActor
func renderSurface<Content: View>(
    _ name: String, size: CGSize, palette: DesignPalette, into directory: URL,
    @ViewBuilder content: () -> Content
) throws {
    // Capture through a real window and `NSHostingView` rather than
    // `ImageRenderer`: the surfaces use AppKit-backed controls and scrolling
    // containers, which `ImageRenderer` silently drops. This path rasterises
    // exactly what the app draws on screen.
    let root =
        content()
        .allwardPalette(palette)
        .frame(width: size.width, height: size.height)
        .background(palette[.canvas].swiftUIColor)
        .environment(\.colorScheme, palette.appearance == .dark ? .dark : .light)

    let hosting = NSHostingView(rootView: AnyView(root))
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.appearance = NSAppearance(
        named: palette.appearance == .dark ? .darkAqua : .aqua)

    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.appearance = hosting.appearance
    window.displayIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw QAError.encodingFailed(name)
    }
    rep.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw QAError.encodingFailed(name)
    }
    try data.write(to: directory.appendingPathComponent("\(name).png"))
    print("wrote \(name).png  \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

/// A terminal snapshot exercising the cases a reviewer must actually see:
/// prompts, colour, bold, underline, wide glyphs, emoji, selection, cursor.
func demonstrationSnapshot(columns: Int, rows: Int) -> TerminalSnapshot {
    let terminal = Terminal(
        geometry: TerminalGeometry(columns: columns, rows: rows),
        clock: SystemClock(), scrollbackCapacity: 2000)
    let esc = "\u{1B}"
    var script = ""
    script += "\(esc)]0;esper — omp\u{7}"
    script += "\(esc)]133;A\u{7}"
    script += "\(esc)[38;2;95;179;201m~/src/allward\(esc)[0m \(esc)[1;32m❯\(esc)[0m "
    script += "\(esc)]133;B\u{7}swift build -c release\r\n\(esc)]133;C\u{7}"
    script += "[1/6] Compiling AllwardCore\r\n"
    script += "[2/6] Compiling \(esc)[1mAllwardTerminal\(esc)[0m\r\n"
    script += "[3/6] Compiling AllwardRenderer  \(esc)[38;5;208m⚠ 1 warning\(esc)[0m\r\n"
    script += "[4/6] Compiling AllwardSurfaces\r\n"
    script += "[5/6] Compiling AllwardChrome\r\n"
    script += "[6/6] \(esc)[32mBuild complete\(esc)[0m (12.54s)\r\n"
    script += "\(esc)]133;D;0\u{7}"
    script += "\(esc)]133;A\u{7}"
    script += "\(esc)[38;2;95;179;201m~/src/allward\(esc)[0m \(esc)[1;32m❯\(esc)[0m "
    script += "\(esc)]133;B\u{7}git status --short\r\n\(esc)]133;C\u{7}"
    script += " \(esc)[31mM\(esc)[0m Sources/AllwardChrome/AppModel.swift\r\n"
    script += " \(esc)[32mA\(esc)[0m Sources/AllwardChrome/SurfaceProjection.swift\r\n"
    script += "\(esc)]133;D;0\u{7}"
    script += "\(esc)]133;A\u{7}"
    script += "\(esc)[4munderline\(esc)[0m  \(esc)[3mitalic\(esc)[0m  "
    script += "\(esc)[7minverse\(esc)[0m  \(esc)[9mstrike\(esc)[0m  日本語ワイド  🚀 ✅ 🧭\r\n"
    for index in 0..<8 {
        script += "\(esc)[4\(index)m  \(esc)[0m"
    }
    script += "  "
    for index in 0..<8 {
        script += "\(esc)[10\(index)m  \(esc)[0m"
    }
    script += "\r\n"
    script += "Powerline/Nerd \u{E0B0}\u{E0B2}\u{F09B}\u{F015}\u{F02B}  "
        + "Box \u{2500}\u{2502}\u{250C}\u{2510}\u{2514}\u{2518}\r\n"
    script += "\(esc)]133;A\u{7}"
    script += "\(esc)[38;2;95;179;201m~/src/allward\(esc)[0m \(esc)[1;32m❯\(esc)[0m "
    script += "\(esc)]133;B\u{7}"
    terminal.consume(ArraySlice(Array(script.utf8)))
    return terminal.snapshot()
}

@MainActor
func run() async throws {
    let arguments = CommandLine.arguments
    let directory = URL(
        fileURLWithPath: arguments.count > 1 ? arguments[1] : "./artifacts/visual-qa")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)

    for appearance in [Appearance.dark, Appearance.light] {
        let palette = DesignPalette(appearance: appearance)
        let suffix = appearance == .dark ? "dark" : "light"

        let metrics = FontMetrics.metrics(family: nil, size: 13, scale: 2)
        let snapshot = demonstrationSnapshot(columns: 96, rows: 26)
        let offscreen = try OffscreenRenderer(metrics: metrics)
        let grid = try await offscreen.render(
            snapshot: snapshot, palette: palette, theme:
                appearance == .dark ? .builtInDark : .builtInLight, focused: true)
        try writePNG(grid, to: directory.appendingPathComponent("terminal-grid-\(suffix).png"))
        print("wrote terminal-grid-\(suffix).png  \(grid.width)x\(grid.height)")

        try renderSurface(
            "pane-header-\(suffix)", size: CGSize(width: 900, height: 34), palette: palette,
            into: directory
        ) {
            PaneHeaderView(model: qaPaneHeader(palette: palette), isFocused: true)
        }

        try renderSurface(
            "board-\(suffix)", size: CGSize(width: 980, height: 620), palette: palette,
            into: directory
        ) {
            BoardView(state: .fixture())
        }

        try renderSurface(
            "board-empty-\(suffix)", size: CGSize(width: 980, height: 420), palette: palette,
            into: directory
        ) {
            BoardView(state: .fixture(state: .noSessions))
        }

        try renderSurface(
            "router-\(suffix)", size: CGSize(width: 980, height: 44), palette: palette,
            into: directory
        ) {
            RouterStripView(state: .fixture())
        }

        try renderSurface(
            "digest-\(suffix)", size: CGSize(width: 720, height: 520), palette: palette,
            into: directory
        ) {
            DigestView(state: .fixture())
        }

        try renderSurface(
            "palette-\(suffix)", size: CGSize(width: 700, height: 480), palette: palette,
            into: directory
        ) {
            CommandPaletteView(
                state: .fixture(), onQueryChanged: { _ in }, onSubmit: { _ in },
                dismissAndRestoreInvocation: {})
        }

        try renderSurface(
            "settings-\(suffix)", size: CGSize(width: 860, height: 620), palette: palette,
            into: directory
        ) {
            SettingsView(
                state: .fixture(), onUpdate: { _ in }, dismissAndRestoreInvocation: {})
        }

        try renderSurface(
            "permission-\(suffix)", size: CGSize(width: 640, height: 380), palette: palette,
            into: directory
        ) {
            PermissionView(
                state: .fixture(), onDecision: { _ in }, onAcknowledgeLocally: {},
                onCancelDispatch: {}, onLookupOutcome: {}, onRetry: {},
                dismissAndRestoreSource: {})
        }

        try renderSurface(
            "dictation-\(suffix)", size: CGSize(width: 640, height: 300), palette: palette,
            into: directory
        ) {
            DictationComposerView(
                state: .fixture(), onAssetAction: {}, onRetry: {}, onDiscard: {},
                onInject: {}, cancelAndRestoreLockedTarget: {})
        }

        try renderSurface(
            "concierge-\(suffix)", size: CGSize(width: 700, height: 460), palette: palette,
            into: directory
        ) {
            ConciergeView(
                state: .fixture(), onDryRun: {}, onConfirm: {}, dismissAndRestoreSource: {})
        }

        try renderSurface(
            "onboarding-\(suffix)", size: CGSize(width: 720, height: 520), palette: palette,
            into: directory
        ) {
            OnboardingView(
                state: .fixture(), onPerform: { _ in }, dismissForNow: {}, dismissForever: {})
        }

        try renderSurface(
            "diagnostics-\(suffix)", size: CGSize(width: 860, height: 620), palette: palette,
            into: directory
        ) {
            DiagnosticsView(state: .fixture(), dismissAndRestoreInvocation: {})
        }
    }
    print("visual QA written to \(directory.path)")
}

@MainActor
func qaPaneHeader(palette: DesignPalette) -> PaneHeaderModel {
    PaneHeaderModel(
        roomName: "Work",
        roomTint: palette[.seam],
        showsRoomIdentity: true,
        sessionName: "omp — allward v1",
        host: "esper",
        workspace: "allward",
        paneLabel: "w1G:p1",
        agentState: .working,
        shellRegionsActive: true,
        presentation: PresentationComposer.compose(SourceComposition()),
        subject: PresentationSubject(componentName: "Pane", target: "omp — allward v1"),
        destinationKey: "1")
}

// A real run loop is required: Metal command completion and `ImageRenderer`
// both need the main thread to keep servicing work, so blocking it on a
// semaphore would deadlock before the first frame.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        try await run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("allward-qa failed: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
