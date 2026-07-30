import AllwardCore
import AllwardDesign
import AllwardSpeech
import AppKit
import SwiftUI

@MainActor
public struct DictationComposerView: View {
    @Environment(\.allwardPalette) private var palette

    private let state: DictationViewState
    private let onAssetAction: @MainActor () -> Void
    private let onRetry: @MainActor () -> Void
    private let onDiscard: @MainActor () -> Void
    private let onInject: @MainActor () -> Void
    private let cancelAndRestoreLockedTarget: @MainActor () -> Void

    public init(
        state: DictationViewState,
        onAssetAction: @escaping @MainActor () -> Void,
        onRetry: @escaping @MainActor () -> Void,
        onDiscard: @escaping @MainActor () -> Void,
        onInject: @escaping @MainActor () -> Void,
        cancelAndRestoreLockedTarget: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onAssetAction = onAssetAction
        self.onRetry = onRetry
        self.onDiscard = onDiscard
        self.onInject = onInject
        self.cancelAndRestoreLockedTarget = cancelAndRestoreLockedTarget
    }

    public var body: some View {
        SurfacePanel(
            title: "Dictation",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: cancelAndRestoreLockedTarget,
            focusTitleOnAppear: false
        ) {
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                lockedDestination
                Divider().overlay(palette[.strokeDivider].swiftUIColor)
                stateContent
            }
        }
        .accessibilityLabel("Dictation for \(state.lockedTarget)")
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        .onKeyPress(.escape) {
            cancelAndRestoreLockedTarget()
            return .handled
        }
    }

    private var lockedDestination: some View {
        VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Label("Locked destination", systemImage: "lock.fill")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
            Text(state.lockedTarget)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityLabel("Locked Room, session, and pane: \(state.lockedTarget)")
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state.phase {
        case .ready:
            phaseStatus(
                presentationState: .live,
                title: "Dictation ready",
                detail: "Hold the dictation shortcut to begin"
            )
        case .checkingAccess:
            phaseStatus(
                presentationState: .loading,
                title: "Checking microphone and speech access",
                detail: state.lockedTarget
            )
        case let .denied(permission):
            phaseStatus(
                presentationState: .denied,
                title: "\(permissionName(permission)) access denied",
                detail: permission.systemSettingsPath
            )
        case let .unavailable(reason):
            phaseStatus(
                presentationState: .degraded,
                title: "Dictation unavailable",
                detail: reason.exactReason
            )
            if let actionTitle = state.assetActionTitle {
                actionButton(actionTitle, symbol: "arrow.down.circle", action: onAssetAction)
            }
        case .acquiring:
            phaseStatus(
                presentationState: .loading,
                title: "Acquiring speech analyzer",
                detail: state.lockedTarget
            )
        case .listening:
            phaseStatus(
                presentationState: .running,
                title: "Listening",
                detail: "Recording for the locked destination"
            )
            Label("Recording", systemImage: "record.circle.fill")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.stateRunning, palette)
                .accessibilityLabel("Recording for \(state.lockedTarget)")
        case let .interrupted(cause):
            phaseStatus(
                presentationState: .error,
                title: "Dictation interrupted",
                detail: interruptionName(cause)
            )
            retainedComposerIfPresent
        case .finalizing:
            phaseStatus(
                presentationState: .loading,
                title: "Finalizing dictation",
                detail: "Waiting for the bounded final transcript"
            )
            retainedComposerIfPresent
        case .cancelled:
            phaseStatus(
                presentationState: .empty,
                title: "Dictation cancelled — transcript discarded",
                detail: "No text was inserted"
            )
        case .transcriptRetained:
            if let transcript = state.transcript {
                TranscriptComposer(
                    transcript: transcript,
                    lockedTarget: state.lockedTarget,
                    destinationIsValid: state.destinationIsValid,
                    copy: { copyToClipboard(transcript) },
                    retry: onRetry,
                    discard: onDiscard,
                    inject: onInject
                )
            } else {
                phaseStatus(
                    presentationState: .empty,
                    title: "No transcript captured",
                    detail: "Typed text input remains available"
                )
            }
        case .injected:
            phaseStatus(
                presentationState: .live,
                title: "Text inserted",
                detail: state.lockedTarget
            )
        case let .error(cause):
            phaseStatus(
                presentationState: .error,
                title: "Dictation failed",
                detail: errorName(cause)
            )
            retainedComposerIfPresent
            actionButton("Retry dictation", symbol: "arrow.clockwise", action: onRetry)
        }
    }

    @ViewBuilder
    private var retainedComposerIfPresent: some View {
        if let transcript = state.transcript {
            TranscriptComposer(
                transcript: transcript,
                lockedTarget: state.lockedTarget,
                destinationIsValid: state.destinationIsValid,
                copy: { copyToClipboard(transcript) },
                retry: onRetry,
                discard: onDiscard,
                inject: onInject
            )
        } else {
            Text("No transcript captured")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel("No transcript captured")
        }
    }

    private func phaseStatus(
        presentationState: PresentationState,
        title: String,
        detail: String
    ) -> some View {
        let mark = StateMark.mark(for: presentationState)
        return HStack(alignment: .top, spacing: SpaceToken.inlineStandard.points) {
            Image(systemName: mark.symbolName)
                .tokenForeground(mark.color, palette)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                Text(title)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                Text(detail)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .accessibilityLabel(detail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(state.lockedTarget); \(detail)")
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .tokenFont(.uiBody, palette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SpaceToken.inlineStandard.points)
                .padding(.vertical, SpaceToken.blockCompact.points)
        }
        .buttonStyle(.plain)
        .background(palette[.surfaceRaised].swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
    }

    private func permissionName(_ permission: SpeechPermission) -> String {
        switch permission {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech recognition"
        }
    }

    private func interruptionName(_ cause: SpeechInterruptionCause) -> String {
        switch cause {
        case .routeLost: "Input route lost"
        case .deviceChange: "Audio input device changed"
        case .system: "System interruption"
        }
    }

    private func errorName(_ cause: SpeechErrorCause) -> String {
        switch cause {
        case let .analyzerAcquisitionFailed(reason): "Analyzer acquisition failed: \(reason)"
        case let .analyzerFailed(reason): "Speech analyzer failed: \(reason)"
        case let .finalizationFailed(reason): "Finalization failed: \(reason)"
        case .inputRouteUnavailable: "Input route unavailable"
        case .targetInvalidatedWithoutTranscript: "The locked destination closed before capture completed"
        case let .injectionRejected(reason): "The locked destination rejected text: \(reason)"
        case .injectionOutcomeUnknown: "Text insertion outcome is unknown; the transcript is retained"
        }
    }

    private func copyToClipboard(_ transcript: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }
}

@MainActor
private struct TranscriptComposer: View {
    @Environment(\.allwardPalette) private var palette

    let transcript: String
    let lockedTarget: String
    let destinationIsValid: Bool
    let copy: @MainActor () -> Void
    let retry: @MainActor () -> Void
    let discard: @MainActor () -> Void
    let inject: @MainActor () -> Void

    init(
        transcript: String,
        lockedTarget: String,
        destinationIsValid: Bool,
        copy: @escaping @MainActor () -> Void,
        retry: @escaping @MainActor () -> Void,
        discard: @escaping @MainActor () -> Void,
        inject: @escaping @MainActor () -> Void
    ) {
        self.transcript = transcript
        self.lockedTarget = lockedTarget
        self.destinationIsValid = destinationIsValid
        self.copy = copy
        self.retry = retry
        self.discard = discard
        self.inject = inject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Text("Transcript retained")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(transcript)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpaceToken.blockStandard.points)
            }
            .background(palette[.surfaceRaised].swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
            .accessibilityLabel("Retained dictation transcript for \(lockedTarget)")
            if !destinationIsValid {
                Label("Locked destination is no longer available", systemImage: "lock.slash")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.stateError, palette)
            }
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Button("Copy", action: copy)
                Button("Retry", action: retry)
                    .disabled(!destinationIsValid)
                Button("Discard", role: .destructive, action: discard)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Button("Insert into locked pane", action: inject)
                    .disabled(!destinationIsValid)
            }
            .tokenFont(.uiBody, palette)
        }
    }
}

private enum DictationPreviewFixture {
    static let subject = PresentationSubject(
        componentName: "Dictation",
        target: "Work Room / deploy session / pane 42",
        workKind: "speech capture"
    )

    static let listening = DictationViewState(
        presentation: ComposedPresentation(state: .running, usability: .usableActionCapable),
        subject: subject,
        phase: .listening,
        lockedTarget: "Work Room / deploy session / pane 42",
        transcript: nil,
        destinationIsValid: true,
        assetActionTitle: nil
    )

    static let retained = DictationViewState(
        presentation: ComposedPresentation(state: .needsInput, usability: .usableActionCapable),
        subject: subject,
        phase: .transcriptRetained,
        lockedTarget: "Work Room / deploy session / pane 42",
        transcript: "Inspect the reconnect receipt and summarize the exact typed cause.",
        destinationIsValid: true,
        assetActionTitle: nil
    )
}

#Preview("Dictation listening") {
    DictationComposerView(
        state: DictationPreviewFixture.listening,
        onAssetAction: {},
        onRetry: {},
        onDiscard: {},
        onInject: {},
        cancelAndRestoreLockedTarget: {}
    )
    .allwardPalette(DesignPalette(appearance: .dark, settings: .standard))
}

#Preview("Dictation transcript retained") {
    DictationComposerView(
        state: DictationPreviewFixture.retained,
        onAssetAction: {},
        onRetry: {},
        onDiscard: {},
        onInject: {},
        cancelAndRestoreLockedTarget: {}
    )
    .allwardPalette(DesignPalette(appearance: .light))
}
