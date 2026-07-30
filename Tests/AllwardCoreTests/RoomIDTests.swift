import Foundation
import XCTest

@testable import AllwardCore

final class RoomIDTests: XCTestCase {
  func testJSONRoundTripPreservesIdentity() throws {
    let uuid = try XCTUnwrap(UUID(uuidString: "8A44031C-49CF-4AB9-A502-A143CD03BFD4"))
    let roomID = RoomID(rawValue: uuid)

    let encoded = try JSONEncoder().encode(roomID)
    let decoded = try JSONDecoder().decode(RoomID.self, from: encoded)

    XCTAssertEqual(decoded, roomID)
  }
}
