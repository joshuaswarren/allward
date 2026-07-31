import AllwardRenderer
import AllwardTerminal
import XCTest

@testable import AllwardChrome

/// A shell must start at the size it will occupy. When it does not, its first
/// prompt is drawn into a smaller grid and the rows added afterwards strand it
/// mid-window, which is what these tests exist to prevent coming back.
final class PaneGeometryTests: XCTestCase {
    private func metrics(scale: CGFloat) -> CellMetrics {
        FontMetrics.metrics(family: "Menlo", size: 13, scale: scale)
    }

    func testGridIsTheSameWhicheverScaleRastersTheCells() {
        // Cell metrics are measured in device pixels, so the arithmetic only
        // holds when the grid uses the same scale the cells were rastered at.
        // Mixing scale 2 metrics with a scale 1 window halved every dimension.
        let area = CGSize(width: 1158, height: 748)
        // Hinting means a 1x cell is not exactly half a 2x cell, so the grids
        // agree to within a cell rather than exactly. What must never happen is
        // one being a fraction of the other.
        let atOne = TerminalGeometry.fitting(area, metrics: metrics(scale: 1), scale: 1)
        let atTwo = TerminalGeometry.fitting(area, metrics: metrics(scale: 2), scale: 2)
        XCTAssertLessThanOrEqual(abs(atOne.columns - atTwo.columns), 2)
        XCTAssertLessThanOrEqual(abs(atOne.rows - atTwo.rows), 2)
    }

    func testMismatchedScaleHalvesTheGrid() {
        // The precise failure that stranded the prompt: metrics rastered for a
        // Retina cell, measured against a window still reporting scale 1.
        let area = CGSize(width: 1158, height: 748)
        let correct = TerminalGeometry.fitting(area, metrics: metrics(scale: 2), scale: 2)
        let mismatched = TerminalGeometry.fitting(area, metrics: metrics(scale: 2), scale: 1)
        XCTAssertLessThan(mismatched.rows, correct.rows)
        XCTAssertLessThanOrEqual(abs(mismatched.rows - correct.rows / 2), 1)
    }

    func testAGridNeverCollapsesBelowOneCell() {
        let tiny = TerminalGeometry.fitting(
            CGSize(width: 1, height: 1), metrics: metrics(scale: 2), scale: 2)
        XCTAssertEqual(tiny.columns, 1)
        XCTAssertEqual(tiny.rows, 1)
    }

    @MainActor
    func testInsetsLeaveRoomForTheGrid() {
        // The projected size subtracts the same insets the pane view applies,
        // so the shell and the renderer agree on the row count.
        let pane = CGSize(width: 1178, height: 708)
        let grid = pane.reduced(by: TerminalPaneView.gridInsetSize)
        XCTAssertEqual(grid.width, pane.width - TerminalPaneView.gridInsetSize.width)
        XCTAssertEqual(grid.height, pane.height - TerminalPaneView.gridInsetSize.height)
    }
}
