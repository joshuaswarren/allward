import AllwardCore
import AllwardRenderer
import AllwardTerminal
import AppKit
import SwiftUI

/// Captures the live application window to a PNG.
///
/// `cacheDisplay` cannot read a `CAMetalLayer`, so the terminal surface is
/// re-rendered from the pane's current snapshot through the same `SceneBuilder`
/// the on-screen path uses and composited into the captured chrome. The result
/// is the real window with real session content, not a mock.
///
/// Compositing order matters: a summoned surface covers the panes on screen, so
/// it is redrawn above them here. Painting the terminal last would erase it.
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
        let summoned = (window.windowController as? MainWindowController)?.summonedSurfaceView
        guard let contentView = window.contentView else { throw CaptureError.noWindow }
        // The titlebar and toolbar live above the content view, so capture the
        // window's frame view to evidence the whole window rather than a crop.
        let captureView = contentView.superview ?? contentView
        captureView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else {
            throw CaptureError.bitmapUnavailable
        }
        rep.size = captureView.bounds.size
        captureView.cacheDisplay(in: captureView.bounds, to: rep)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CaptureError.bitmapUnavailable
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (paneID, container) in model.containers {
            guard let snapshot = model.paneView(for: paneID)?.snapshot else { continue }
            let terminal = container.terminal
            let frame = terminal.convert(terminal.bounds, to: captureView)
            guard frame.width > 1, frame.height > 1 else { continue }
            let image = try await renderTerminal(
                snapshot: snapshot, view: terminal, model: model)
            NSImage(cgImage: image, size: frame.size)
                .draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let summoned,
            let overlay = summoned.bitmapImageRepForCachingDisplay(in: summoned.bounds)
        {
            overlay.size = summoned.bounds.size
            summoned.cacheDisplay(in: summoned.bounds, to: overlay)
            NSImage(size: summoned.bounds.size, flipped: false) { _ in
                overlay.draw(in: CGRect(origin: .zero, size: summoned.bounds.size))
            }
            .draw(
                in: summoned.convert(summoned.bounds, to: captureView),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }
        try data.write(to: url)
    }

    private static func renderTerminal(
        snapshot: TerminalSnapshot, view: TerminalPaneView, model: AppModel
    ) async throws -> CGImage {
        let renderer = try OffscreenRenderer(metrics: view.metrics)
        return try await renderer.render(
            snapshot: snapshot,
            palette: model.palette,
            theme: model.terminalTheme,
            focused: true)
    }
}
