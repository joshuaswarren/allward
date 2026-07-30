@preconcurrency import AVFoundation
import AllwardCore
@preconcurrency import Foundation
@preconcurrency import Speech

public struct SpeechStatusUpdate: Hashable, Sendable {
    public var state: SpeechState
    public var outcome: SpeechOutcome
    public var lockedDestination: LockedSpeechDestination?

    public init(
        state: SpeechState,
        outcome: SpeechOutcome,
        lockedDestination: LockedSpeechDestination?
    ) {
        self.state = state
        self.outcome = outcome
        self.lockedDestination = lockedDestination
    }
}

public struct LockedComposerTranscript: Hashable, Sendable {
    public var destination: LockedSpeechDestination
    public var text: String
    public var isFinal: Bool

    public init(destination: LockedSpeechDestination, text: String, isFinal: Bool) {
        self.destination = destination
        self.text = text
        self.isFinal = isFinal
    }
}


public actor DictationSession {
    public typealias StatusHandler = @Sendable (SpeechStatusUpdate) async -> Void
    public typealias ComposerHandler = @Sendable (LockedComposerTranscript) async -> Void

    private let locale: Locale
    private let statusHandler: StatusHandler
    private let composerHandler: ComposerHandler
    private let routeLocking: any InputRouteLocking
    private let audioEngine = AVAudioEngine()

    private var transition = SpeechTransition(state: .ready)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var configurationObserver: (any NSObjectProtocol)?
    private var finalizationDeadline: Task<Void, Never>?
    private var tapIsInstalled = false
    private var acquisitionGeneration = Generation.initial

    public init(
        locale: Locale = .current,
        routeLocking: any InputRouteLocking,
        statusHandler: @escaping StatusHandler,
        composerHandler: @escaping ComposerHandler
    ) {
        self.locale = locale
        self.routeLocking = routeLocking
        self.statusHandler = statusHandler
        self.composerHandler = composerHandler
    }

    deinit {
        finalizationDeadline?.cancel()
        recognitionTask?.cancel()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    public var state: SpeechState { transition.state }

    public func press(generation: Generation) async {
        guard transition.state == .ready else {
            if let destination = transition.lockedDestination {
                await apply(.press(destination))
            }
            return
        }
        guard let inputRoute = await routeLocking.lockCurrentInputRoute(),
              inputRoute.canSendText else {
            await apply(.targetInvalidated)
            return
        }
        acquisitionGeneration = acquisitionGeneration.next
        let destination = LockedSpeechDestination(
            target: inputRoute.target,
            generation: generation,
            inputRoute: inputRoute
        )
        await apply(.press(destination))
    }

    public func release() async {
        await apply(.release)
    }

    public func cancel() async {
        await apply(.escape)
    }

    public func interrupt(_ cause: SpeechInterruptionCause) async {
        await apply(.interruption(cause))
    }

    public func targetInvalidated() async {
        await apply(.targetInvalidated)
    }

    public func inject(currentTarget: Target, currentGeneration: Generation) async {
        await apply(.requestInjection(currentTarget: currentTarget, currentGeneration: currentGeneration))
    }

    public func settle() async {
        await apply(.settle)
    }

    private func apply(_ input: SpeechInput) async {
        let reduction = SpeechTransitionReducer.reduce(transition, input: input)
        transition = reduction.transition

        await statusHandler(
            SpeechStatusUpdate(
                state: reduction.transition.state,
                outcome: reduction.outcome,
                lockedDestination: reduction.transition.lockedDestination
            )
        )

        if case .partialTranscript = input,
           reduction.outcome == .advanced,
           let destination = transition.lockedDestination,
           let transcript = transition.transcript {
            await composerHandler(
                LockedComposerTranscript(destination: destination, text: transcript, isFinal: false)
            )
        }

        for action in reduction.actions {
            await execute(action)
        }
    }

    private func execute(_ action: SpeechAction) async {
        switch action {
        case .requestAuthorization:
            let authorization = await requestAuthorization()
            await apply(.authorizationResult(authorization))

        case .acquireAnalyzer:
            await acquireAnalyzer()


        case .requestFinalTranscript:
            requestFinalTranscript()

        case .stopCapture:
            stopCapture(cancelRecognition: true)

        case let .presentLockedComposer(destination):
            if let transcript = transition.transcript {
                await composerHandler(
                    LockedComposerTranscript(
                        destination: destination,
                        text: transcript,
                        isFinal: transition.transcriptIsFinal
                    )
                )
            }

        case let .injectText(destination, text):
            guard destination.inputRoute.canSendText else {
                await apply(.targetInvalidated)
                return
            }
            switch await routeLocking.injectAtomically(text, using: destination.inputRoute) {
            case .injected:
                await apply(.injectionSucceeded)
            case let .rejectedBeforeAnyByte(reason):
                await apply(.injectionFailed(.rejectedBeforeAnyByte(reason: reason)))
            case .outcomeUnknown:
                await apply(.injectionFailed(.outcomeUnknown))
            }

        case .releaseResources:
            releaseResources()
        }
    }

    private func requestAuthorization() async -> SpeechAuthorizationResult {
        let microphone: SpeechAuthorizationStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .authorized
        case .denied:
            microphone = .denied
        case .restricted:
            microphone = .restricted
        case .notDetermined:
            microphone = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        @unknown default:
            microphone = .restricted
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speech: SpeechAuthorizationStatus
        if speechStatus == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: Self.mapSpeechAuthorization(status))
                }
            }
        } else {
            speech = Self.mapSpeechAuthorization(speechStatus)
        }

        return SpeechAuthorizationResult(microphone: microphone, speech: speech)
    }

    private nonisolated static func mapSpeechAuthorization(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> SpeechAuthorizationStatus {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    private func acquireAnalyzer() async {
        let localeIdentifier = locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            await apply(.analyzerFailed(.unavailable(.recognizerUnavailable(locale: localeIdentifier))))
            return
        }
        guard recognizer.isAvailable else {
            await apply(.analyzerFailed(.unavailable(.recognizerUnavailable(locale: localeIdentifier))))
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            await apply(
                .analyzerFailed(.unavailable(.onDeviceRecognitionUnavailable(locale: localeIdentifier)))
            )
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            await apply(.analyzerFailed(.unavailable(.noAudioInput)))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionRequest = request
        installRecognitionTask(recognizer: recognizer, request: request)
        installAudioTap(input: input, format: format, request: request)
        installConfigurationObserver()
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            await apply(.analyzerFailed(.acquisitionFailed(error.localizedDescription)))
            return
        }
        await apply(.analyzerAcquired)
    }

    private func installRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        let callbackGeneration = acquisitionGeneration
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { [weak self] in
                    await self?.receivedTranscript(
                        text,
                        isFinal: isFinal,
                        acquisitionGeneration: callbackGeneration
                    )
                }
            } else if let error {
                let reason = error.localizedDescription
                Task { [weak self] in
                    await self?.recognitionFailed(reason, acquisitionGeneration: callbackGeneration)
                }
            }
        }
    }

    private func installAudioTap(
        input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapIsInstalled = true
    }

    private func installConfigurationObserver() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.interrupt(.deviceChange)
            }
        }
    }


    private func requestFinalTranscript() {
        recognitionRequest?.endAudio()
        stopAudioInput()
        finalizationDeadline?.cancel()
        let timeout = AttemptBound.localPrepare.totalTimeout
        finalizationDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.finalizationTimedOut()
        }
    }

    private func receivedTranscript(
        _ text: String,
        isFinal: Bool,
        acquisitionGeneration callbackGeneration: Generation
    ) async {
        guard callbackGeneration == acquisitionGeneration else { return }
        guard let destination = transition.lockedDestination else { return }
        if isFinal {
            finalizationDeadline?.cancel()
            await apply(.finalTranscript(generation: destination.generation, text: text))
        } else {
            await apply(.partialTranscript(generation: destination.generation, text: text))
        }
    }

    private func recognitionFailed(
        _ reason: String,
        acquisitionGeneration callbackGeneration: Generation
    ) async {
        guard callbackGeneration == acquisitionGeneration else { return }
        guard transition.state == .listening || transition.state == .finalizing else { return }
        await apply(.analyzerFailed(.acquisitionFailed(reason)))
    }

    private func finalizationTimedOut() async {
        guard transition.state == .finalizing else { return }
        await apply(.analyzerFailed(.acquisitionFailed("Final transcript timed out")))
    }

    private func stopAudioInput() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapIsInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
    }

    private func stopCapture(cancelRecognition: Bool) {
        finalizationDeadline?.cancel()
        finalizationDeadline = nil
        recognitionRequest?.endAudio()
        stopAudioInput()
        if cancelRecognition {
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
        }
    }

    private func releaseResources() {
        stopCapture(cancelRecognition: true)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }
}
