import Foundation
import XCTest

@testable import AllwardControl
import AllwardCore

final class SplitTreeTests: XCTestCase {
  func testSplitReplacesLeafAndPreservesReadingOrder() throws {
    let first = pane("00000000-0000-0000-0000-000000000001")
    let second = pane("00000000-0000-0000-0000-000000000002")
    let tree = try SplitTree.leaf(first).splitting(
      pane: first,
      newPane: second,
      orientation: .horizontal,
      ratio: 0.4
    )

    XCTAssertEqual(tree.leaves, [first, second])
    guard case let .split(orientation, ratio, children) = tree else {
      return XCTFail("Expected a split root")
    }
    XCTAssertEqual(orientation, .horizontal)
    XCTAssertEqual(ratio, 0.4, accuracy: 0.000_001)
    XCTAssertEqual(children.first, .leaf(first))
    XCTAssertEqual(children.second, .leaf(second))
  }

  func testClosePromotesSiblingWithoutChangingOtherBranches() throws {
    let first = pane("00000000-0000-0000-0000-000000000001")
    let second = pane("00000000-0000-0000-0000-000000000002")
    let third = pane("00000000-0000-0000-0000-000000000003")
    let nested = SplitTree.split(
      orientation: .vertical,
      ratio: 0.5,
      children: SplitChildren(first: .leaf(second), second: .leaf(third))
    )
    let tree = SplitTree.split(
      orientation: .horizontal,
      ratio: 0.35,
      children: SplitChildren(first: .leaf(first), second: nested)
    )

    let closed = try XCTUnwrap(try tree.closing(pane: second))

    XCTAssertEqual(closed.leaves, [first, third])
    XCTAssertEqual(
      closed,
      .split(
        orientation: .horizontal,
        ratio: 0.35,
        children: SplitChildren(first: .leaf(first), second: .leaf(third))
      )
    )
  }

  func testDirectionalFocusAcrossNestedSplitsIsDeterministic() {
    let left = pane("00000000-0000-0000-0000-000000000001")
    let upperRight = pane("00000000-0000-0000-0000-000000000002")
    let lowerRight = pane("00000000-0000-0000-0000-000000000003")
    let right = SplitTree.split(
      orientation: .vertical,
      ratio: 0.5,
      children: SplitChildren(first: .leaf(upperRight), second: .leaf(lowerRight))
    )
    let tree = SplitTree.split(
      orientation: .horizontal,
      ratio: 0.5,
      children: SplitChildren(first: .leaf(left), second: right)
    )

    XCTAssertEqual(tree.focus(from: left, moving: .right), upperRight)
    XCTAssertEqual(tree.focus(from: upperRight, moving: .down), lowerRight)
    XCTAssertEqual(tree.focus(from: lowerRight, moving: .left), left)
    XCTAssertNil(tree.focus(from: left, moving: .left))
  }

  func testCodableDescriptionRestoresSameTree() throws {
    let first = pane("00000000-0000-0000-0000-000000000001")
    let second = pane("00000000-0000-0000-0000-000000000002")
    let original = SplitTree.split(
      orientation: .vertical,
      ratio: 0.625,
      children: SplitChildren(first: .leaf(first), second: .leaf(second))
    )
    let encoded = try JSONEncoder().encode(original.description)
    let decoded = try JSONDecoder().decode(SplitTreeDescription.self, from: encoded)

    XCTAssertEqual(try SplitTree.restore(from: decoded), original)
  }

  private func pane(_ value: String) -> PaneID {
    PaneID(rawValue: UUID(uuidString: value)!)
  }
}
