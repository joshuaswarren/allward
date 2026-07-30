import AllwardCore
import Foundation

public struct InputRouteLock: Hashable, Sendable {
    public let target: Target
    public let routeHandle: UUID
    public let routeGeneration: Generation
    public let ownershipGeneration: Generation
    public let canSendText: Bool

    public init(
        target: Target,
        routeHandle: UUID,
        routeGeneration: Generation,
        ownershipGeneration: Generation,
        canSendText: Bool
    ) {
        self.target = target
        self.routeHandle = routeHandle
        self.routeGeneration = routeGeneration
        self.ownershipGeneration = ownershipGeneration
        self.canSendText = canSendText
    }
}

public enum InputRouteInjectionResult: Hashable, Sendable {
    case injected
    case rejectedBeforeAnyByte(reason: String)
    case outcomeUnknown
}

public protocol InputRouteLocking: Sendable {
    func lockCurrentInputRoute() async -> InputRouteLock?
    func injectAtomically(_ text: String, using lock: InputRouteLock) async -> InputRouteInjectionResult
}

public struct LockedSpeechDestination: Hashable, Sendable {
    public let target: Target
    public let generation: Generation
    public let inputRoute: InputRouteLock

    public init(target: Target, generation: Generation, inputRoute: InputRouteLock) {
        self.target = target
        self.generation = generation
        self.inputRoute = inputRoute
    }
}

public enum SpeechPermission: String, Hashable, Sendable, CaseIterable {
    case microphone
    case speechRecognition

    public var systemSettingsPath: String {
        switch self {
        case .microphone:
            "System Settings > Privacy & Security > Microphone"
        case .speechRecognition:
            "System Settings > Privacy & Security > Speech Recognition"
        }
    }
}

public enum SpeechAuthorizationStatus: Hashable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public struct SpeechAuthorizationResult: Hashable, Sendable {
    public var microphone: SpeechAuthorizationStatus
    public var speech: SpeechAuthorizationStatus

    public init(microphone: SpeechAuthorizationStatus, speech: SpeechAuthorizationStatus) {
        self.microphone = microphone
        self.speech = speech
    }
}

public enum SpeechUnavailableReason: Hashable, Sendable {
    case recognizerUnavailable(locale: String)
    case onDeviceRecognitionUnavailable(locale: String)
    case noAudioInput

    public var exactReason: String {
        switch self {
        case let .recognizerUnavailable(locale):
            "Speech recognition is unavailable for \(locale)"
        case let .onDeviceRecognitionUnavailable(locale):
            "On-device speech recognition is unavailable for \(locale)"
        case .noAudioInput:
            "No audio input device is available"
        }
    }
}

public enum SpeechInterruptionCause: String, Hashable, Sendable, CaseIterable {
    case routeLost
    case deviceChange
    case system
}

public enum SpeechAnalyzerFailure: Hashable, Sendable {
    case unavailable(SpeechUnavailableReason)
    case acquisitionFailed(String)
}

public enum SpeechInjectionFailure: Hashable, Sendable {
    case rejectedBeforeAnyByte(reason: String)
    case outcomeUnknown
}

public enum SpeechErrorCause: Hashable, Sendable {
    case analyzerAcquisitionFailed(String)
    case analyzerFailed(String)
    case finalizationFailed(String)
    case inputRouteUnavailable
    case targetInvalidatedWithoutTranscript
    case injectionRejected(String)
    case injectionOutcomeUnknown
}

public enum SpeechState: Hashable, Sendable {
    case ready
    case checkingAccess
    case denied(SpeechPermission)
    case unavailable(SpeechUnavailableReason)
    case acquiring
    case listening
    case interrupted(SpeechInterruptionCause)
    case finalizing
    case cancelled
    case transcriptRetained
    case injected
    case error(SpeechErrorCause)
}

public struct SpeechTransition: Hashable, Sendable {
    public var state: SpeechState
    public var lockedDestination: LockedSpeechDestination?
    public var transcript: String?
    public var transcriptIsFinal: Bool
    public var destinationIsValid: Bool
    public var injectionIsPending: Bool
    public var injectionMayRetry: Bool

    public init(
        state: SpeechState,
        lockedDestination: LockedSpeechDestination? = nil,
        transcript: String? = nil,
        transcriptIsFinal: Bool = false,
        destinationIsValid: Bool = true,
        injectionIsPending: Bool = false,
        injectionMayRetry: Bool = true
    ) {
        self.state = state
        self.lockedDestination = lockedDestination
        self.transcript = transcript?.nilIfEmpty
        self.transcriptIsFinal = transcriptIsFinal
        self.destinationIsValid = destinationIsValid
        self.injectionIsPending = injectionIsPending
        self.injectionMayRetry = injectionMayRetry
    }
}

public enum SpeechInput: Hashable, Sendable {
    case press(LockedSpeechDestination)
    case release
    case escape
    case authorizationResult(SpeechAuthorizationResult)
    case analyzerAcquired
    case analyzerFailed(SpeechAnalyzerFailure)
    case partialTranscript(generation: Generation, text: String)
    case finalTranscript(generation: Generation, text: String)
    case interruption(SpeechInterruptionCause)
    case targetInvalidated
    case requestInjection(currentTarget: Target, currentGeneration: Generation)
    case injectionSucceeded
    case injectionFailed(SpeechInjectionFailure)
    case settle
}

public enum SpeechInvalidTransition: Hashable, Sendable {
    case inputNotAccepted(state: SpeechState, input: SpeechInput)
    case authorizationIncomplete
    case staleCallback(expected: Generation, actual: Generation)
    case missingDestination
    case missingTranscript
    case injectionAlreadyPending
    case injectionRetryDisabled
}

public enum SpeechInjectionBlock: Hashable, Sendable {
    case targetChanged(expected: Target, actual: Target)
    case generationChanged(expected: Generation, actual: Generation)
    case destinationInvalidated
}

public enum SpeechOutcome: Hashable, Sendable {
    case advanced
    case accessDenied(SpeechPermission, settingsPath: String)
    case unavailable(SpeechUnavailableReason)
    case cancelled(discardedTranscript: Bool)
    case interrupted(SpeechInterruptionCause, retainedTranscript: Bool)
    case transcriptRetained
    case injectionRequested
    case injectionBlocked(SpeechInjectionBlock)
    case injected
    case failed(SpeechErrorCause, retainedTranscript: Bool)
    case settled
    case rejected(SpeechInvalidTransition)
}

public enum SpeechAction: Hashable, Sendable {
    case requestAuthorization(LockedSpeechDestination)
    case acquireAnalyzer(LockedSpeechDestination)
    case requestFinalTranscript
    case stopCapture
    case presentLockedComposer(LockedSpeechDestination)
    case injectText(LockedSpeechDestination, String)
    case releaseResources


    public var injectsText: Bool {
        if case .injectText = self { return true }
        return false
    }

    public var injectedText: String? {
        if case let .injectText(_, text) = self { return text }
        return nil
    }
}

public struct SpeechReduction: Hashable, Sendable {
    public var transition: SpeechTransition
    public var outcome: SpeechOutcome
    public var actions: [SpeechAction]

    public init(transition: SpeechTransition, outcome: SpeechOutcome, actions: [SpeechAction] = []) {
        self.transition = transition
        self.outcome = outcome
        self.actions = actions
    }
}

public enum SpeechTransitionReducer {
    public static func reduce(_ current: SpeechTransition, input: SpeechInput) -> SpeechReduction {
        switch (current.state, input) {
        case (.ready, .targetInvalidated):
            return failed(current, cause: .inputRouteUnavailable, wasCapturing: false)

        case (.ready, let .press(destination)):
            guard destination.inputRoute.target == destination.target,
                  destination.inputRoute.canSendText else {
                return SpeechReduction(
                    transition: SpeechTransition(
                        state: .error(.inputRouteUnavailable),
                        lockedDestination: destination,
                        destinationIsValid: false
                    ),
                    outcome: .failed(.inputRouteUnavailable, retainedTranscript: false),
                    actions: [.releaseResources]
                )
            }
            return result(
                .checkingAccess,
                destination: destination,
                outcome: .advanced,
                actions: [.requestAuthorization(destination)]
            )

        case (.checkingAccess, let .authorizationResult(authorization)):
            if authorization.microphone == .denied || authorization.microphone == .restricted {
                return denied(.microphone, current: current)
            }
            if authorization.speech == .denied || authorization.speech == .restricted {
                return denied(.speechRecognition, current: current)
            }
            guard authorization.microphone == .authorized, authorization.speech == .authorized else {
                return rejected(current, .authorizationIncomplete)
            }
            guard let destination = current.lockedDestination else {
                return rejected(current, .missingDestination)
            }
            return result(
                .acquiring,
                destination: destination,
                outcome: .advanced,
                actions: [.acquireAnalyzer(destination)]
            )

        case (.checkingAccess, .release), (.checkingAccess, .escape),
             (.acquiring, .release), (.acquiring, .escape):
            return cancelled(current, wasCapturing: false)

        case (.acquiring, .analyzerAcquired):
            return SpeechReduction(
                transition: replacing(current, state: .listening),
                outcome: .advanced
            )

        case (.acquiring, let .analyzerFailed(.unavailable(reason))):
            return SpeechReduction(
                transition: replacing(current, state: .unavailable(reason)),
                outcome: .unavailable(reason),
                actions: [.releaseResources]
            )

        case (.acquiring, let .analyzerFailed(.acquisitionFailed(reason))):
            let cause = SpeechErrorCause.analyzerAcquisitionFailed(reason)
            return failed(current, cause: cause, wasCapturing: false)

        case (.listening, let .partialTranscript(generation, text)):
            return transcriptCallback(current, generation: generation, text: text, isFinal: false)

        case (.listening, let .finalTranscript(generation, text)),
             (.finalizing, let .finalTranscript(generation, text)):
            return transcriptCallback(current, generation: generation, text: text, isFinal: true)

        case (.listening, .release):
            return SpeechReduction(
                transition: replacing(current, state: .finalizing),
                outcome: .advanced,
                actions: [.requestFinalTranscript]
            )

        case (.listening, .escape), (.finalizing, .escape):
            return cancelled(current, wasCapturing: true)

        case (.listening, let .interruption(cause)), (.finalizing, let .interruption(cause)):
            return interrupted(current, cause: cause)

        case (.listening, .targetInvalidated), (.finalizing, .targetInvalidated):
            return invalidated(current, wasCapturing: true)

        case (.listening, let .analyzerFailed(.acquisitionFailed(reason))):
            return failed(current, cause: .analyzerFailed(reason), wasCapturing: true)

        case (.listening, let .analyzerFailed(.unavailable(reason))):
            return failed(current, cause: .analyzerFailed(reason.exactReason), wasCapturing: true)

        case (.finalizing, let .analyzerFailed(.acquisitionFailed(reason))):
            return failed(current, cause: .finalizationFailed(reason), wasCapturing: true)

        case (.finalizing, let .analyzerFailed(.unavailable(reason))):
            return failed(current, cause: .finalizationFailed(reason.exactReason), wasCapturing: true)

        case (.acquiring, .targetInvalidated), (.checkingAccess, .targetInvalidated):
            return invalidated(current, wasCapturing: false)

        case (.transcriptRetained, .targetInvalidated):
            var retained = current
            retained.destinationIsValid = false
            retained.injectionIsPending = false
            return SpeechReduction(
                transition: retained,
                outcome: .injectionBlocked(.destinationInvalidated)
            )

        case (.transcriptRetained, let .requestInjection(target, generation)):
            return requestInjection(current, currentTarget: target, currentGeneration: generation)

        case (.transcriptRetained, .injectionSucceeded) where current.injectionIsPending:
            return SpeechReduction(
                transition: SpeechTransition(state: .injected),
                outcome: .injected,
                actions: [.releaseResources]
            )

        case (.transcriptRetained, let .injectionFailed(failure)) where current.injectionIsPending:
            var retained = current
            retained.injectionIsPending = false
            let cause: SpeechErrorCause
            switch failure {
            case let .rejectedBeforeAnyByte(reason):
                cause = .injectionRejected(reason)
                retained.state = .error(cause)
            case .outcomeUnknown:
                cause = .injectionOutcomeUnknown
                retained.state = .transcriptRetained
                retained.injectionMayRetry = false
            }
            return SpeechReduction(
                transition: retained,
                outcome: .failed(cause, retainedTranscript: true)
            )

        case (.transcriptRetained, .escape):
            return cancelled(current, wasCapturing: false)

        case (.interrupted, .settle), (.error, .settle):
            if current.transcript != nil {
                return SpeechReduction(
                    transition: replacing(current, state: .transcriptRetained),
                    outcome: .transcriptRetained
                )
            }
            return settled()

        case (.denied, .settle), (.unavailable, .settle), (.cancelled, .settle), (.injected, .settle):
            return settled()

        default:
            return rejected(current, .inputNotAccepted(state: current.state, input: input))
        }
    }

    private static func transcriptCallback(
        _ current: SpeechTransition,
        generation: Generation,
        text: String,
        isFinal: Bool
    ) -> SpeechReduction {
        guard let destination = current.lockedDestination else {
            return rejected(current, .missingDestination)
        }
        guard generation == destination.generation else {
            return rejected(current, .staleCallback(expected: destination.generation, actual: generation))
        }

        let normalized = text.nilIfEmpty
        if !isFinal {
            var listening = current
            listening.transcript = normalized
            listening.transcriptIsFinal = false
            return SpeechReduction(transition: listening, outcome: .advanced)
        }
        guard normalized != nil else {
            return failed(current, cause: .analyzerFailed("No transcript captured"), wasCapturing: true)
        }

        return SpeechReduction(
            transition: SpeechTransition(
                state: .transcriptRetained,
                lockedDestination: destination,
                transcript: normalized,
                transcriptIsFinal: true
            ),
            outcome: .transcriptRetained,
            actions: [.stopCapture, .presentLockedComposer(destination)]
        )
    }

    private static func requestInjection(
        _ current: SpeechTransition,
        currentTarget: Target,
        currentGeneration: Generation
    ) -> SpeechReduction {
        guard !current.injectionIsPending else {
            return rejected(current, .injectionAlreadyPending)
        }
        guard current.injectionMayRetry else {
            return rejected(current, .injectionRetryDisabled)
        }
        guard let destination = current.lockedDestination else {
            return rejected(current, .missingDestination)
        }
        guard let transcript = current.transcript else {
            return rejected(current, .missingTranscript)
        }
        guard current.destinationIsValid else {
            return SpeechReduction(transition: current, outcome: .injectionBlocked(.destinationInvalidated))
        }
        guard currentTarget == destination.target else {
            return SpeechReduction(
                transition: current,
                outcome: .injectionBlocked(.targetChanged(expected: destination.target, actual: currentTarget))
            )
        }
        guard currentGeneration == destination.generation else {
            return SpeechReduction(
                transition: current,
                outcome: .injectionBlocked(
                    .generationChanged(expected: destination.generation, actual: currentGeneration)
                )
            )
        }

        var pending = current
        pending.injectionIsPending = true
        return SpeechReduction(
            transition: pending,
            outcome: .injectionRequested,
            actions: [.injectText(destination, transcript)]
        )
    }

    private static func denied(_ permission: SpeechPermission, current: SpeechTransition) -> SpeechReduction {
        SpeechReduction(
            transition: replacing(current, state: .denied(permission)),
            outcome: .accessDenied(permission, settingsPath: permission.systemSettingsPath),
            actions: [.releaseResources]
        )
    }

    private static func cancelled(_ current: SpeechTransition, wasCapturing: Bool) -> SpeechReduction {
        let hadTranscript = current.transcript != nil
        return SpeechReduction(
            transition: SpeechTransition(state: .cancelled),
            outcome: .cancelled(discardedTranscript: hadTranscript),
            actions: wasCapturing ? [.stopCapture, .releaseResources] : [.releaseResources]
        )
    }

    private static func interrupted(
        _ current: SpeechTransition,
        cause: SpeechInterruptionCause
    ) -> SpeechReduction {
        var actions: [SpeechAction] = [.stopCapture, .releaseResources]
        if current.transcript != nil, let destination = current.lockedDestination {
            actions.append(.presentLockedComposer(destination))
        }
        return SpeechReduction(
            transition: replacing(current, state: .interrupted(cause)),
            outcome: .interrupted(cause, retainedTranscript: current.transcript != nil),
            actions: actions
        )
    }

    private static func invalidated(_ current: SpeechTransition, wasCapturing: Bool) -> SpeechReduction {
        if current.transcript != nil {
            var retained = replacing(current, state: .transcriptRetained)
            retained.destinationIsValid = false
            var actions: [SpeechAction] = wasCapturing ? [.stopCapture, .releaseResources] : [.releaseResources]
            if let destination = current.lockedDestination {
                actions.append(.presentLockedComposer(destination))
            }
            return SpeechReduction(
                transition: retained,
                outcome: .injectionBlocked(.destinationInvalidated),
                actions: actions
            )
        }
        return failed(current, cause: .targetInvalidatedWithoutTranscript, wasCapturing: wasCapturing)
    }

    private static func failed(
        _ current: SpeechTransition,
        cause: SpeechErrorCause,
        wasCapturing: Bool
    ) -> SpeechReduction {
        var actions: [SpeechAction] = wasCapturing ? [.stopCapture, .releaseResources] : [.releaseResources]
        if current.transcript != nil, let destination = current.lockedDestination {
            actions.append(.presentLockedComposer(destination))
        }
        return SpeechReduction(
            transition: replacing(current, state: .error(cause)),
            outcome: .failed(cause, retainedTranscript: current.transcript != nil),
            actions: actions
        )
    }

    private static func settled() -> SpeechReduction {
        SpeechReduction(
            transition: SpeechTransition(state: .ready),
            outcome: .settled,
            actions: [.releaseResources]
        )
    }

    private static func rejected(
        _ current: SpeechTransition,
        _ reason: SpeechInvalidTransition
    ) -> SpeechReduction {
        SpeechReduction(transition: current, outcome: .rejected(reason))
    }

    private static func result(
        _ state: SpeechState,
        destination: LockedSpeechDestination,
        outcome: SpeechOutcome,
        actions: [SpeechAction]
    ) -> SpeechReduction {
        SpeechReduction(
            transition: SpeechTransition(state: state, lockedDestination: destination),
            outcome: outcome,
            actions: actions
        )
    }

    private static func replacing(_ current: SpeechTransition, state: SpeechState) -> SpeechTransition {
        var replacement = current
        replacement.state = state
        replacement.injectionIsPending = false
        return replacement
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
