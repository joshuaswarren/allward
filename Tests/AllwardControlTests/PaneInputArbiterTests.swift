import Foundation
import XCTest

@testable import AllwardControl
import AllwardCore

final class PaneInputArbiterTests: XCTestCase {
  func testConcurrentWritersAreDeliveredInFIFOOrder() async {
    let pane = PaneID()
    let target = Target(room: RoomID(), session: SessionID(), pane: pane)
    let arbiter = PaneInputArbiter()
    let gate = AsyncGate()
    let recorder = StringRecorder()

    let first = Task {
      await arbiter.submit(
        pane: pane,
        target: target,
        expectedGeneration: .initial,
        source: .mcp,
        currentGeneration: { .initial },
        deliver: {
          await recorder.append("first")
          await gate.enter()
          return true
        }
      )
    }
    await gate.waitUntilEntered()
    let second = Task {
      await arbiter.submit(
        pane: pane,
        target: target,
        expectedGeneration: .initial,
        source: .speech,
        currentGeneration: { .initial },
        deliver: {
          await recorder.append("second")
          return true
        }
      )
    }

    let beforeOpen = await recorder.values()
    XCTAssertEqual(beforeOpen, ["first"])
    await gate.open()
    _ = await first.value
    _ = await second.value
    let afterOpen = await recorder.values()
    XCTAssertEqual(afterOpen, ["first", "second"])
  }

  func testQueuedInjectionIsDroppedWhenGenerationChanges() async {
    let pane = PaneID()
    let target = Target(room: RoomID(), session: SessionID(), pane: pane)
    let arbiter = PaneInputArbiter()
    let gate = AsyncGate()
    let generation = GenerationBox(.initial)
    let recorder = StringRecorder()

    let first = Task {
      await arbiter.submit(
        pane: pane,
        target: target,
        expectedGeneration: .initial,
        source: .mcp,
        currentGeneration: { await generation.value() },
        deliver: {
          await gate.enter()
          return true
        }
      )
    }
    await gate.waitUntilEntered()
    let queued = Task {
      await arbiter.submit(
        pane: pane,
        target: target,
        expectedGeneration: .initial,
        source: .speech,
        currentGeneration: { await generation.value() },
        deliver: {
          await recorder.append("delivered-late")
          return true
        }
      )
    }

    await generation.set(Generation(rawValue: 1))
    await gate.open()
    _ = await first.value
    let result = await queued.value

    XCTAssertEqual(
      result,
      .dropped(
        .staleGeneration(
          expected: .initial,
          actual: Generation(rawValue: 1)
        )
      )
    )
    let delivered = await recorder.values()
    XCTAssertEqual(delivered, [])
  }
}

private actor AsyncGate {
  private var entered = false
  private var opened = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    entered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    guard !opened else { return }
    await withCheckedContinuation { openWaiters.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func open() {
    opened = true
    for waiter in openWaiters { waiter.resume() }
    openWaiters.removeAll()
  }
}

private actor StringRecorder {
  private var recorded: [String] = []
  func append(_ value: String) { recorded.append(value) }
  func values() -> [String] { recorded }
}

private actor GenerationBox {
  private var generation: Generation
  init(_ generation: Generation) { self.generation = generation }
  func value() -> Generation { generation }
  func set(_ generation: Generation) { self.generation = generation }
}
