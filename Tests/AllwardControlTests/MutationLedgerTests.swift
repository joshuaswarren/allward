import XCTest

@testable import AllwardControl
import AllwardCore

final class MutationLedgerTests: XCTestCase {
  func testRetryReturnsRecordedResultWithoutDispatchingAgain() async throws {
    let ledger = MutationLedger(maximumEntries: 4)
    let counter = InvocationCounter()
    let key = IdempotencyKey("same-call")
    let target = Target(room: RoomID())
    let expected = ControlMutationResult.applied(
      ControlMutationReceipt(
        kind: .createTab,
        target: target,
        generationBefore: .initial,
        generationAfter: .initial.next
      )
    )

    let first = try await ledger.perform(key: key) {
      await counter.increment()
      return expected
    }
    let retry = try await ledger.perform(key: key) {
      await counter.increment()
      return ControlMutationResult.rejected(.unsupported("must not run"))
    }

    let invocationCount = await counter.value()
    XCTAssertEqual(first, expected)
    XCTAssertEqual(retry, expected)
    XCTAssertEqual(invocationCount, 1)
  }

  func testLookupNeverDispatchesMissingOutcome() async throws {
    let ledger = MutationLedger(maximumEntries: 4)
    let result: ControlMutationResult? = try await ledger.lookup(
      IdempotencyKey("missing"),
      as: ControlMutationResult.self
    )
    XCTAssertNil(result)
  }
}

private actor InvocationCounter {
  private var count = 0
  func increment() { count += 1 }
  func value() -> Int { count }
}
