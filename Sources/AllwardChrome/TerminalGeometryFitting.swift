import AllwardRenderer
import AllwardTerminal
import CoreGraphics

extension TerminalGeometry {
    /// The grid that fits a pixel area at the given cell metrics.
    ///
    /// A shell must be started at the size it will actually occupy. Spawning at
    /// a placeholder size and correcting afterwards leaves the first prompt
    /// stranded wherever the smaller grid put it, which is why this is shared
    /// rather than recomputed at each call site.
    public static func fitting(
        _ size: CGSize, metrics: CellMetrics, scale: CGFloat
    ) -> TerminalGeometry {
        let columns = Int((size.width * scale / metrics.cellWidth).rounded(.down))
        let rows = Int((size.height * scale / metrics.cellHeight).rounded(.down))
        return TerminalGeometry(columns: max(1, columns), rows: max(1, rows))
    }
}

extension CGSize {
    /// The area left after a pane's grid insets.
    func reduced(by insets: CGSize) -> CGSize {
        CGSize(width: max(1, width - insets.width), height: max(1, height - insets.height))
    }
}
