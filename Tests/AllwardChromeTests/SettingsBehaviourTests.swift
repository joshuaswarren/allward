import AllwardConfig
import AllwardCore
import AllwardDesign
import AllwardRooms
import AllwardTerminal
import XCTest

@testable import AllwardChrome

/// Every settings control must change something.
///
/// A control that renders but refuses is worse than a missing one: it tells the
/// user a preference exists, they set it, and nothing happens. Three shipped
/// this way at once - a theme picker that wrote a field nothing read, an
/// integration toggle whose handler rejected it, and an opt-in button whose
/// handler answered "informational". None of them failed a build, because
/// nothing asserted that a projected control has a handler behind it.
///
/// So that is what this asserts: the settings surface and the mutation handler
/// are checked against each other, by id, in both directions.
final class SettingsBehaviourTests: XCTestCase {
    private func configuration() -> Configuration { Configuration() }

    /// The ids the projection actually renders as writable controls.
    @MainActor
    private func projectedWritableIDs() -> Set<String> {
        let state = SurfaceProjection.settings(
            configuration(),
            rooms: [.personal, .work],
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: .none,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133"
        )
        let groups = state.general + state.appearance + state.sound
        return Set(groups.filter(\.isEnabled).map(\.id))
    }

    @MainActor
    func testEveryWritableSettingIsAccepted() {
        var configuration = self.configuration()
        for id in projectedWritableIDs() {
            let value = Self.plausibleValue(for: id, configuration: configuration)
            let accepted = AppModel.applySetting(
                itemID: id, value: value, to: &configuration)
            XCTAssertTrue(
                accepted,
                "The settings surface renders '\(id)' as writable but the handler refused it. "
                    + "Either wire it up or stop projecting it.")
        }
    }

    @MainActor
    func testNoSettingIsOfferedTwice() {
        let state = SurfaceProjection.settings(
            configuration(),
            rooms: [.personal, .work],
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: .none,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133"
        )
        var seen: Set<String> = []
        for item in state.general + state.appearance + state.sound {
            XCTAssertTrue(
                seen.insert(item.id).inserted,
                "'\(item.id)' is offered in more than one place. Two controls for one "
                    + "value means one of them is going to look broken.")
        }
        for key in state.keys {
            XCTAssertFalse(
                seen.contains(key.id),
                "'\(key.id)' is both a general setting and a key binding.")
        }
    }

    /// The Terminal section is for the terminal. Anything else there is the
    /// grab-bag that made the section unreadable in the first place.
    @MainActor
    func testTheTerminalSectionOnlyHoldsTerminalSettings() {
        let state = SurfaceProjection.settings(
            configuration(),
            rooms: [.personal, .work],
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: .none,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133"
        )
        for item in state.general {
            XCTAssertTrue(
                item.id.hasPrefix("terminal.") || item.id.hasPrefix("shell."),
                "'\(item.id)' is not a terminal setting; it belongs on a section named "
                    + "for what it does.")
        }
    }

    /// Rooms were fixed at Personal and Work, and the empty state pointed at a
    /// Room switcher that could not create one.
    func testRoomsCanBeCreatedRenamedAndDeleted() throws {
        var rooms = [Room.personal, Room.work]

        let added = try XCTUnwrap(RoomMutation.add(to: &rooms))
        XCTAssertEqual(rooms.count, 3)
        XCTAssertTrue(rooms.contains { $0.id == added.id })

        XCTAssertTrue(RoomMutation.rename(added.id, to: "Client", in: &rooms))
        XCTAssertEqual(rooms.first { $0.id == added.id }?.name, "Client")

        XCTAssertTrue(RoomMutation.delete(added.id, from: &rooms))
        XCTAssertEqual(rooms.count, 2)
    }

    /// A Room the panes still live in cannot simply vanish.
    func testTheLastRoomCannotBeDeleted() {
        var rooms = [Room.personal]
        XCTAssertFalse(
            RoomMutation.delete(Room.personal.id, from: &rooms),
            "Deleting the only Room would leave sessions with nowhere to belong.")
        XCTAssertEqual(rooms.count, 1)
    }

    /// Dictation audio retention was offered as an opt-in behind a button that
    /// did nothing. There is no reason to offer it at all.
    @MainActor
    func testDictationAudioRetentionIsNotOffered() {
        let state = SurfaceProjection.settings(
            configuration(),
            rooms: [.personal],
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: .none,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133"
        )
        let speech = state.privacy.first { $0.id == "speech-retention" }
        XCTAssertEqual(
            speech?.value, .disabled,
            "Dictation audio is discarded. Retention must not be a setting.")
    }

    /// A switch the handler will refuse is worse than no switch. herdr appears
    /// when a herdr server runs; it is a readout, and it renders as one.
    @MainActor
    func testOnlySwitchableIntegrationsRenderASwitch() {
        var configuration = self.configuration()
        let state = SurfaceProjection.settings(
            configuration,
            rooms: [.personal],
            themes: ThemeCatalog.builtIns.map(\.name),
            adapterHealth: .none,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133"
        )
        XCTAssertFalse(state.integrations.isEmpty)
        for integration in state.integrations where integration.isSwitchable {
            XCTAssertTrue(
                AppModel.applyIntegration(
                    integration.id, enabled: !integration.isEnabled, to: &configuration),
                "'\(integration.id)' renders a switch but the handler refuses it.")
        }
    }

    private static func plausibleValue(
        for id: String, configuration: Configuration
    ) -> GeneralSettingValue {
        switch id {
        case "terminal.font-family": .text("Menlo")
        case "terminal.font-size": .number(value: 14, range: 6...72, step: 1)
        case "terminal.cursor-shape":
            .choice(selectedID: CursorShape.allCases[0].rawValue, choices: [])
        case "terminal.cursor-blink": .toggle(true)
        case "terminal.scrollback-capacity":
            .number(value: 5000, range: 1...10_000_000, step: 1000)
        case "attention.bar":
            .choice(selectedID: AttentionBarVisibility.always.rawValue, choices: [])
        case "board.presentation":
            .choice(selectedID: BoardPresentation.allCases[0].rawValue, choices: [])
        case "earcons.enabled": .toggle(false)
        default: .toggle(true)
        }
    }
}
