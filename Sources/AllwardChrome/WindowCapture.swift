import AllwardCore
import AllwardRenderer
import AllwardTerminal
import AppKit
import SwiftUI

/// Captures the live application window to a PNG.
///
/// `cacheDisplay` cannot read a `CAMetalLayer`, so each pane is re-rendered
/// from its current snapshot through the same `SceneBuilder` the on-screen path
/// uses and composited into the captured chrome. Pane frames are converted into
/// the capture view's own coordinates, so a pane lands exactly where it is laid
/// out and never paints over the toolbar or tab strip above it.
@MainActor
public enum WindowCapture {
    public enum CaptureError: Error {
        case noWindow
        case bitmapUnavailable
        case encodingFailed
    }

    public static func capture(
        window: NSWindow, model: AppModel, to url: URL
    ) async throws {
        guard let contentView = window.contentView else { throw CaptureError.noWindow }
        // The titlebar and toolbar live above the content view, so capture the
        // window's frame view to evidence the whole window rather than a crop.
        let captureView = contentView.superview ?? contentView

        // Hand each pane a still of its grid and let AppKit place it. Nothing
        // is composited by hand, so a pane cannot land on the wrong rows.
        var stilled: [TerminalPaneView] = []
        defer { for view in stilled { view.showCaptureStill(nil) } }
        for (paneID, container) in model.containers {
            guard let view = model.paneView(for: paneID), let snapshot = view.snapshot,
                view.bounds.width > 1, view.bounds.height > 1
            else { continue }
            view.showCaptureStill(
                try await renderTerminal(
                    snapshot: snapshot, view: container.terminal, model: model,
                    focused: view.isPaneFocused))
            stilled.append(view)
        }

        captureView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else {
            throw CaptureError.bitmapUnavailable
        }
        rep.size = captureView.bounds.size
        captureView.cacheDisplay(in: captureView.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }
        try data.write(to: url)
    }

    private static func renderTerminal(
        snapshot: TerminalSnapshot, view: TerminalPaneView, model: AppModel,
        focused: Bool
    ) async throws -> CGImage {
        let renderer = try OffscreenRenderer(metrics: view.metrics)
        return try await renderer.render(
            snapshot: snapshot,
            palette: model.palette,
            theme: model.terminalTheme,
            focused: focused)
    }
}
