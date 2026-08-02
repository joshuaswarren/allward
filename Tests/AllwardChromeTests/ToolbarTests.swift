import AllwardConfig
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

    /// A toolbar button carries its tooltip on a view, or macOS has nothing to
    /// attach the hover to. Setting `NSToolbarItem.toolTip` and leaving `view`
    /// nil put the text on an object with no tracking rect: every item had a
    /// tooltip and none of them ever appeared.
    @MainActor
    func testEveryButtonPutsItsTooltipOnAView() {
        for command in commands {
            let item = SurfaceToolbarItem(
                itemIdentifier: command.id, label: command.label, symbol: command.symbol,
                help: command.help, unavailableHelp: command.unavailableHelp,
                action: command.action)
            item.validate()
            XCTAssertEqual(
                item.view?.toolTip, command.help,
                "'\(command.label)' has no tooltip on its view, so hovering shows nothing.")
        }
    }

    /// A command that can be unavailable must be able to say why. Going dim
    /// without explanation is the same dead end as doing nothing.
    @MainActor
    func testAnUnavailableButtonExplainsItself() throws {
        let teleport = try XCTUnwrap(commands.first { $0.label == "Teleport" })
        let unavailable = try XCTUnwrap(
            teleport.unavailableHelp, "Teleport goes dim with no destination; it has to say so.")

        let item = SurfaceToolbarItem(
            itemIdentifier: teleport.id, label: teleport.label, symbol: teleport.symbol,
            help: teleport.help, unavailableHelp: unavailable, action: teleport.action)
        item.isAvailable = { false }
        item.validate()
        XCTAssertFalse(item.isEnabled, "With nothing to jump to, the button must be dim.")
        XCTAssertEqual(item.view?.toolTip, unavailable)

        item.isAvailable = { true }
        item.validate()
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.view?.toolTip, teleport.help)
    }

    /// `arrow.uturn.forward` is the redo arrow. A button that means something
    /// else must not wear it.
    @MainActor
    func testNoButtonWearsTheUndoArrow() {
        for command in commands {
            XCTAssertFalse(
                command.symbol.hasPrefix("arrow.uturn"),
                "'\(command.label)' uses \(command.symbol), which reads as undo or redo.")
        }
    }

    /// A refusal has to reach the person who asked.
    ///
    /// `lastActionMessage` was read by nothing but the capture harness, so
    /// every refusal in the application was invisible - the action simply
    /// appeared to do nothing. The strip carries them now.
    @MainActor
    func testARefusalMakesTheStripAppear() {
        XCTAssertFalse(
            RouterStripView.isVisible(actionableCount: 0, hasItems: false, message: nil),
            "With nothing to say and nothing to do, the strip stays away.")
        XCTAssertTrue(
            RouterStripView.isVisible(
                actionableCount: 0, hasItems: false,
                message: "The attention router has no actionable destination."),
            "A refusal with nowhere to appear is the same as no refusal at all.")
        XCTAssertTrue(
            RouterStripView.isVisible(actionableCount: 2, hasItems: true, message: nil))
    }

    /// The bar arrived unannounced and could not be dismissed.
    ///
    /// It appears on its own the moment an adapter starts reporting sessions,
    /// which is right by default but was the only behaviour available. Whether
    /// a permanent band belongs at the bottom of your window is your call.
    @MainActor
    func testTheAttentionBarHonoursThePreference() {
        XCTAssertFalse(
            RouterStripView.isVisible(
                actionableCount: 5, hasItems: true, message: "something",
                preference: .hidden),
            "Never means never, even with work waiting.")
        XCTAssertTrue(
            RouterStripView.isVisible(
                actionableCount: 0, hasItems: false, message: nil, preference: .always),
            "Always means the window does not change height under you.")
        XCTAssertFalse(
            RouterStripView.isVisible(
                actionableCount: 0, hasItems: false, message: nil, preference: .automatic))
        XCTAssertTrue(
            RouterStripView.isVisible(
                actionableCount: 2, hasItems: true, message: nil, preference: .automatic))
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
