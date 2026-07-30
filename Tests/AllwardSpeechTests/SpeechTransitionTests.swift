import AllwardCore
import Foundation
import XCTest

@testable import AllwardSpeech

final class SpeechTransitionTests: XCTestCase {
  private let destination: LockedSpeechDestination = {
    let target = Target(room: RoomID(), session: SessionID(), pane: PaneID())
    let inputRoute = InputRouteLock(
      target: target,
      routeHandle: UUID(),
      routeGeneration: Generation(rawValue: 11),
      ownershipGeneration: Generation(rawValue: 13),
      canSendText: true
    )
    return LockedSpeechDestination(
      target: target,
      generation: Generation(rawValue: 7),
      inputRoute: inputRoute
    )
  }()

  func testEveryInputFromEveryStateHasDefinedExit() {
    let text = "retained words"
    let states: [SpeechTransition] = [
      .init(state: .ready),
      .init(state: .checkingAccess, lockedDestination: destination),
      .init(state: .denied(.microphone)),
      .init(state: .unavailable(.onDeviceRecognitionUnavailable(locale: "en-US"))),
      .init(state: .acquiring, lockedDestination: destination),
      .init(state: .listening, lockedDestination: destination, transcript: text),
      .init(state: .interrupted(.system), lockedDestination: destination, transcript: text),
      .init(state: .finalizing, lockedDestination: destination, transcript: text),
      .init(state: .cancelled),
      .init(state: .transcriptRetained, lockedDestination: destination, transcript: text),
      .init(state: .injected),
      .init(state: .error(.analyzerAcquisitionFailed("fixture"))),
    ]
    let inputs: [SpeechInput] = [
      .press(destination),
      .release,
      .escape,
      .authorizationResult(.init(microphone: .authorized, speech: .authorized)),
      .analyzerAcquired,
      .analyzerFailed(.unavailable(.onDeviceRecognitionUnavailable(locale: "en-US"))),
      .partialTranscript(generation: destination.generation, text: "partial"),
      .finalTranscript(generation: destination.generation, text: "final"),
      .interruption(.routeLost),
      .targetInvalidated,
      .requestInjection(currentTarget: destination.target, currentGeneration: destination.generation),
      .injectionSucceeded,
      .injectionFailed(.rejectedBeforeAnyByte(reason: "fixture")),
      .settle,
    ]

    for state in states {
      for input in inputs {
        let result = SpeechTransitionReducer.reduce(state, input: input)
        switch result.outcome {
        case .advanced, .accessDenied, .unavailable, .cancelled, .interrupted,
             .transcriptRetained, .injectionRequested, .injectionBlocked,
             .injected, .failed, .settled:
          break
        case .rejected:
          XCTAssertEqual(result.transition, state)
          XCTAssertTrue(result.actions.isEmpty)
        }
      }
    }
  }

  func testEscapeDuringAccessCheckCapturesNothing() {
    let checking = SpeechTransitionReducer.reduce(.init(state: .ready), input: .press(destination)).transition
    let result = SpeechTransitionReducer.reduce(checking, input: .escape)

    XCTAssertEqual(result.transition.state, .cancelled)
    XCTAssertNil(result.transition.transcript)
    XCTAssertEqual(result.actions, [.releaseResources])
  }

  func testGenerationChangeBlocksInjectionAndRetainsTranscript() {
    let retained = reachRetainedTranscript("do not retarget")
    let result = SpeechTransitionReducer.reduce(
      retained,
      input: .requestInjection(
        currentTarget: destination.target,
        currentGeneration: destination.generation.next
      )
    )

    XCTAssertEqual(result.transition.state, .transcriptRetained)
    XCTAssertEqual(result.transition.transcript, "do not retarget")
    XCTAssertEqual(
      result.outcome,
      .injectionBlocked(
        .generationChanged(expected: destination.generation, actual: destination.generation.next)
      )
    )
    XCTAssertFalse(result.actions.contains(where: \.injectsText))
  }

  func testInjectionNeverAppendsReturn() {
    let retained = reachRetainedTranscript("write this\n")
    let result = SpeechTransitionReducer.reduce(
      retained,
      input: .requestInjection(
        currentTarget: destination.target,
        currentGeneration: destination.generation
      )
    )

    let injectedText = result.actions.compactMap(\.injectedText)
    XCTAssertEqual(injectedText, ["write this\n"])
    XCTAssertEqual(injectedText.first?.utf8.count, "write this\n".utf8.count)
  }

  func testDuplicateInjectionRequestIsRejectedWhileDispatchIsPending() {
    let retained = reachRetainedTranscript("once")
    let request = SpeechInput.requestInjection(
      currentTarget: destination.target,
      currentGeneration: destination.generation
    )
    let pending = SpeechTransitionReducer.reduce(retained, input: request).transition
    let duplicate = SpeechTransitionReducer.reduce(pending, input: request)

    XCTAssertEqual(duplicate.outcome, .rejected(.injectionAlreadyPending))
    XCTAssertTrue(duplicate.actions.isEmpty)
  }

  func testUnknownInjectionOutcomeCannotBeRetried() {
    let retained = reachRetainedTranscript("once")
    let request = SpeechInput.requestInjection(
      currentTarget: destination.target,
      currentGeneration: destination.generation
    )
    let pending = SpeechTransitionReducer.reduce(retained, input: request).transition
    let unknown = SpeechTransitionReducer.reduce(
      pending,
      input: .injectionFailed(.outcomeUnknown)
    ).transition
    let retry = SpeechTransitionReducer.reduce(unknown, input: request)

    XCTAssertEqual(retry.outcome, .rejected(.injectionRetryDisabled))
    XCTAssertTrue(retry.actions.isEmpty)
  }

  private func reachRetainedTranscript(_ text: String) -> SpeechTransition {
    var transition = SpeechTransitionReducer.reduce(.init(state: .ready), input: .press(destination)).transition
    transition = SpeechTransitionReducer.reduce(
      transition,
      input: .authorizationResult(.init(microphone: .authorized, speech: .authorized))
    ).transition
    transition = SpeechTransitionReducer.reduce(transition, input: .analyzerAcquired).transition
    return SpeechTransitionReducer.reduce(
      transition,
      input: .finalTranscript(generation: destination.generation, text: text)
    ).transition
  }
}
