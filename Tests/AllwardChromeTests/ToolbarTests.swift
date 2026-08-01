import AppKit
import XCTest

@testable import AllwardChrome

/// Every toolbar button must do something no other button does.
///
/// The bell and the Board button ran the same call for as long as both
/// existed: `focusRouter` was a copy of `showBoard`. Nothing caught it, because
/// nothing compared the buttons to each other - each one worked.
final class ToolbarTests: XCTestCase {
    @MainActor
    private var commands: [MainWindowController.ToolbarCommand] {
        MainWindowController.toolbarCommands
    }

    @MainActor
    func testNoTwoButtonsRunTheSameAction() {
        var seen: [Selector: String] = [:]
        for command in commands {
            if let owner = seen[command.action] {
                XCTFail(
                    "'\(command.label)' and '\(owner)' both run \(command.action). "
                        + "Two buttons for one job is one button too many.")
            }
            seen[command.action] = command.label
        }
    }

    @MainActor
    func testEveryButtonIsIdentifiedAndExplained() {
        var ids: Set<NSToolbarItem.Identifier> = []
        for command in commands {
            XCTAssertTrue(
                ids.insert(command.id).inserted, "Duplicate toolbar id \(command.id.rawValue).")
            XCTAssertFalse(command.label.isEmpty)
            // The toolbar is icon-only, so the tooltip is the only text a
            // person gets. An icon alone does not say what a button does.
            XCTAssertFalse(
                command.help.isEmpty,
                "'\(command.label)' has no tooltip, so its icon is the only explanation.")
            XCTAssertNotNil(
                NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil),
                "'\(command.symbol)' is not a system symbol, so '\(command.label)' renders blank.")
        }
    }
}
