import AllwardCore
import AllwardDesign
import AllwardRooms
import XCTest

@testable import AllwardChrome
@testable import AllwardHerdr
@testable import AllwardMultiplexer

final class RoomAdaptersTests: XCTestCase {
    func testEachRoomUsesAndRetainsItsOwnHerdrAdapter() async throws {
        let roomA = Room(
            name: "A", baseTint: TokenColor(hex: "#5aa0ff")!, terminalThemeName: "Allward Night"
        ).connectedToHerdr(HostAlias("alpha"))
        let roomB = Room(
            name: "B", baseTint: TokenColor(hex: "#3ecde8")!, terminalThemeName: "Allward Night"
        ).connectedToHerdr(HostAlias("beta"))
        let switchable = SwitchableAdapter()
        let coordinator = RoomAdapters(switchable: switchable)

        await coordinator.activate(roomA)
        let adapterA = try XCTUnwrap(switchable.current as? HerdrAdapter)
        XCTAssertEqual(adapterA.endpoint.host, HostAlias("alpha"))

        await coordinator.activate(roomB)
        let adapterB = try XCTUnwrap(switchable.current as? HerdrAdapter)
        XCTAssertEqual(adapterB.endpoint.host, HostAlias("beta"))
        XCTAssertFalse(adapterA === adapterB)

        await coordinator.activate(roomA)
        let returnedA = try XCTUnwrap(switchable.current as? HerdrAdapter)
        XCTAssertTrue(returnedA === adapterA)
    }
}
