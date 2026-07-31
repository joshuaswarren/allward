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
        // A summoned surface covers the panes on screen, so it is redrawn above
        // them here. Painting the terminal last would erase it.
        if let summoned = (window.windowController as? MainWindowController)?
            .summonedSurfaceView,
            let overlay = summoned.bitmapImageRepForCachingDisplay(in: summoned.bounds)
        {
            overlay.size = summoned.bounds.size
            summoned.cacheDisplay(in: summoned.bounds, to: overlay)
            NSImage(size: summoned.bounds.size, flipped: false) { rect in
                overlay.draw(in: rect)
                return true
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
