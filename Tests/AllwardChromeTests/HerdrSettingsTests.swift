import AllwardConfig
import AllwardCore
import AllwardDesign
import AllwardRooms
import XCTest

@testable import AllwardChrome

final class HerdrSettingsTests: XCTestCase {
    @MainActor
    func testConnectingUpdatesOnlyTheActiveRoom() throws {
        var configuration = Configuration()
        let activeRoom = configuration.rooms[0]

        let failure = AppModel.applyHerdrConnection(
            host: "user@example.com", activeRoom: activeRoom, to: &configuration)

        XCTAssertNil(failure)
        XCTAssertEqual(configuration.rooms[0].herdrHost, HostAlias(rawValue: "user@example.com"))
        XCTAssertEqual(
            configuration.rooms[0].adapterServers,
            [AdapterServerReference(adapterIdentifier: "herdr", serverIdentifier: "user@example.com")])
        XCTAssertNil(configuration.rooms[1].herdrHost)
        try configuration.validate()
    }

    @MainActor
    func testDisconnectingRemovesTheActiveRoomsHerdrServer() {
        let host = HostAlias(rawValue: "herdr.example.com")
        let otherHost = HostAlias(rawValue: "other-herdr.example.com")
        let activeRoom = Room.personal.connectedToHerdr(host)
        let otherRoom = Room.work.connectedToHerdr(otherHost)
        var configuration = Configuration(
            rooms: [activeRoom, otherRoom],
            hosts: [
                HostConfiguration(alias: host, hostname: host.rawValue),
                HostConfiguration(alias: otherHost, hostname: otherHost.rawValue),
            ])

        let failure = AppModel.applyHerdrConnection(
            host: nil, activeRoom: activeRoom, to: &configuration)

        XCTAssertNil(failure)
        XCTAssertNil(configuration.rooms[0].herdrHost)
        XCTAssertTrue(configuration.rooms[0].adapterServers.isEmpty)
        XCTAssertEqual(configuration.rooms[1].herdrHost, otherHost)
    }

    @MainActor
    func testConnectingToAnotherRoomsHerdrServerNamesTheOwner() {
        let host = HostAlias(rawValue: "shared-herdr")
        let owner = Room.work.connectedToHerdr(host)
        var configuration = Configuration(
            rooms: [Room.personal, owner],
            hosts: [HostConfiguration(alias: host, hostname: "shared.example.com")])

        let failure = AppModel.applyHerdrConnection(
            host: host.rawValue, activeRoom: Room.personal, to: &configuration)

        XCTAssertEqual(failure, "shared-herdr is already assigned to Room Work.")
        XCTAssertNil(configuration.rooms[0].herdrHost)
    }

    @MainActor
    func testIntegrationsReportTheActiveRoomsHerdrServer() throws {
        let firstHost = HostAlias(rawValue: "personal-herdr")
        let secondHost = HostAlias(rawValue: "work-herdr")
        let first = Room.personal.connectedToHerdr(firstHost)
        let second = Room.work.connectedToHerdr(secondHost)
        let configuration = Configuration(
            rooms: [first, second],
            hosts: [
                HostConfiguration(alias: firstHost, hostname: "personal.example.com"),
                HostConfiguration(alias: secondHost, hostname: "work.example.com"),
            ])

        let firstState = SurfaceProjection.settings(
            configuration,
            rooms: [first, second],
            activeRoom: first,
            themes: [],
            adapterHealth: .available,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133")
        let secondState = SurfaceProjection.settings(
            configuration,
            rooms: [first, second],
            activeRoom: second,
            themes: [],
            adapterHealth: .available,
            mcpCommandLine: "allward-mcp",
            shellLane: "OSC 133")

        XCTAssertEqual(firstState.integrations.first(where: { $0.id == "herdr" })?.configuredValue, "personal-herdr")
        XCTAssertEqual(secondState.integrations.first(where: { $0.id == "herdr" })?.configuredValue, "work-herdr")
        let firstIntegration = try XCTUnwrap(firstState.integrations.first(where: { $0.id == "herdr" }))
        let secondIntegration = try XCTUnwrap(secondState.integrations.first(where: { $0.id == "herdr" }))
        XCTAssertTrue(firstIntegration.detail?.contains("personal-herdr") == true)
        XCTAssertTrue(secondIntegration.detail?.contains("work-herdr") == true)
    }
}
