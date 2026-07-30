import AllwardCore
import AllwardDesign
import SwiftUI

@MainActor
public struct PermissionView: View {
    private enum FocusTarget: Hashable {
        case localAcknowledgment
        case option(String)
        case cancel
        case lookup
        case retry
        case dismiss
    }

    @Environment(\.allwardPalette) private var palette
    @FocusState private var focus: FocusTarget?

    private let state: PermissionViewState
    private let onDecision: @MainActor (PermissionOption) -> Void
    private let onAcknowledgeLocally: @MainActor () -> Void
    private let onCancelDispatch: @MainActor () -> Void
    private let onLookupOutcome: @MainActor () -> Void
    private let onRetry: @MainActor () -> Void
    private let dismissAndRestoreSource: @MainActor () -> Void

    public init(
        state: PermissionViewState,
        onDecision: @escaping @MainActor (PermissionOption) -> Void,
        onAcknowledgeLocally: @escaping @MainActor () -> Void,
        onCancelDispatch: @escaping @MainActor () -> Void,
        onLookupOutcome: @escaping @MainActor () -> Void,
        onRetry: @escaping @MainActor () -> Void,
        dismissAndRestoreSource: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onDecision = onDecision
        self.onAcknowledgeLocally = onAcknowledgeLocally
        self.onCancelDispatch = onCancelDispatch
        self.onLookupOutcome = onLookupOutcome
        self.onRetry = onRetry
        self.dismissAndRestoreSource = dismissAndRestoreSource
    }

    public var body: some View {
        SurfacePanel(
            title: "Publisher decision",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissAndRestoreSource,
            focusTitleOnAppear: false
        ) {
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                decisionHeader
                Divider().overlay(palette[.strokeDivider].swiftUIColor)
                phaseContent
            }
        }
        .accessibilityLabel("\(state.subject.target), publisher decision")
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        .onKeyPress(.escape) {
            dismissAndRestoreSource()
            return .handled
        }
        .onKeyPress(.return) {
            submitFocusedDecision()
        }
        .task {
            focusLeastDestructiveControl()
        }
    }

    private var decisionHeader: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                if let expires = state.expires {
                    Text(expires)
                        .tokenFont(.uiData, palette)
                        .tokenForeground(.textSecondary, palette)
                        .accessibilityLabel("Permission expires \(expires)")
                }
            }
            Text(state.publisher)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel("Publisher, \(state.publisher)")
            Text(state.target)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityLabel("Exact target, \(state.target)")
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .ready:
            readyContent
        case let .dispatching(decision, cancellable):
            statusContent(
                state: .running,
                title: "Sending \(decision) to \(state.publisher)",
                detail: state.target
            )
            if cancellable {
                actionButton("Cancel decision", symbol: "xmark", focusTarget: .cancel, action: onCancelDispatch)
            }
        case .accepted:
            statusContent(
                state: .running,
                title: "Decision accepted — awaiting publisher commit",
                detail: "No decision can be sent again while this transaction is active"
            )
            dismissButton
        case let .committed(receipt):
            statusContent(
                state: .finished,
                title: "Decision committed",
                detail: "Granted · \(receipt)"
            )
            dismissButton
        case let .rejected(reason):
            statusContent(
                state: .denied,
                title: "Decision rejected by publisher",
                detail: reason
            )
            actionButton("Review current request", symbol: "arrow.clockwise", focusTarget: .retry, action: onRetry)
        case .cancelled:
            statusContent(
                state: .empty,
                title: "Decision cancelled — not committed",
                detail: "No permission was granted"
            )
            dismissButton
        case let .acknowledged(outcome, receipt):
            statusContent(
                state: .live,
                title: "Publisher acknowledged \(outcome)",
                detail: receipt
            )
            dismissButton
        case let .outcomeUnknown(transaction):
            statusContent(
                state: .stale,
                title: "Decision result unknown — checking publisher",
                detail: "Transaction \(transaction) · \(state.target)"
            )
            actionButton(
                "Check recorded outcome",
                symbol: "magnifyingglass",
                focusTarget: .lookup,
                action: onLookupOutcome
            )
        case let .stale(reason):
            statusContent(state: .stale, title: "Decision is stale", detail: reason)
            actionButton("Inspect source", symbol: "doc.text.magnifyingglass", focusTarget: .retry, action: onRetry)
        case let .error(reason, recovery):
            ErrorStateView(
                operation: "Publisher decision",
                target: state.target,
                cause: reason,
                recovery: recovery,
            )
            actionButton("Retry decision", symbol: "arrow.clockwise", focusTarget: .retry, action: onRetry)
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Text("Choose what \(state.publisher) may do")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textPrimary, palette)
                .accessibilityAddTraits(.isHeader)
            Label(state.verb, systemImage: "questionmark.circle")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.statePermission, palette)
                .accessibilityLabel("Requested decision, \(state.verb)")
            ForEach(state.options, id: \.id) { option in
                actionButton(
                    option.verb,
                    symbol: option.isLeastDestructive ? "hand.raised" : "checkmark",
                    focusTarget: .option(option.id)
                ) {
                    onDecision(option)
                }
                .disabled(!state.decisionEnabled)
                .accessibilityValue("\(option.verb), \(state.publisher), \(state.target)")
            }
            if state.localAcknowledgmentAvailable {
                Divider().overlay(palette[.strokeDivider].swiftUIColor)
                actionButton(
                    "Acknowledge locally",
                    symbol: "eye.slash",
                    focusTarget: .localAcknowledgment,
                    action: onAcknowledgeLocally
                )
                .accessibilityHint("Clears Allward attention only. Sends no decision to the publisher.")
            }
        }
    }

    private func statusContent(state phaseState: PresentationState, title: String, detail: String) -> some View {
        let presentation = ComposedPresentation(state: phaseState, usability: state.presentation.usability)
        let mark = StateMark.mark(for: phaseState)
        let subject = PresentationSubject(
            componentName: "Publisher decision",
            target: state.target,
            reason: detail,
            source: state.publisher,
            workKind: title,
            resultKind: detail
        )
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
        .accessibilityValue(presentation.accessibilityValue(subject))
    }

    private var dismissButton: some View {
        actionButton("Close", symbol: "xmark", focusTarget: .dismiss, action: dismissAndRestoreSource)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        focusTarget: FocusTarget,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .tokenFont(.uiBody, palette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SpaceToken.inlineStandard.points)
                .padding(.vertical, SpaceToken.blockCompact.points)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(palette[.surfaceRaised].swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
        .focused($focus, equals: focusTarget)
        .modifier(KeyboardFocusRing(isFocused: focus == focusTarget, palette: palette))
    }

    private func focusLeastDestructiveControl() {
        if case .ready = state.phase {
            if let option = state.options.first(where: \.isLeastDestructive) ?? state.options.first {
                focus = .option(option.id)
            } else if state.localAcknowledgmentAvailable {
                focus = .localAcknowledgment
            } else {
                focus = .dismiss
            }
            return
        }
        switch state.phase {
        case let .dispatching(_, cancellable) where cancellable:
            focus = .cancel
        case .outcomeUnknown:
            focus = .lookup
        case .rejected, .stale, .error:
            focus = .retry
        default:
            focus = .dismiss
        }
    }

    private func submitFocusedDecision() -> KeyPress.Result {
        guard case let .option(identifier) = focus,
              state.decisionEnabled,
              let option = state.options.first(where: { $0.id == identifier })
        else {
            return .ignored
        }
        onDecision(option)
        return .handled
    }
}

private enum PermissionPreviewFixture {
    static let subject = PresentationSubject(
        componentName: "Publisher decision",
        target: "Work Room / deploy session / pane 42",
        verb: "Allow once",
        source: "Claude Code"
    )

    static let ready = PermissionViewState(
        publisher: "Claude Code",
        target: "Work Room / deploy session / pane 42",
        verb: "Allow file write once",
        expires: "2m 14s",
        options: [
            PermissionOption(id: "deny", verb: "Deny", isLeastDestructive: true),
            PermissionOption(id: "once", verb: "Allow once", isLeastDestructive: false),
            PermissionOption(id: "session", verb: "Allow for session", isLeastDestructive: false)
        ],
        localAcknowledgmentAvailable: true,
        phase: .ready,
        decisionEnabled: true,
        presentation: ComposedPresentation(state: .needsInput, usability: .usableActionCapable),
        subject: subject
    )

    static let unknown = PermissionViewState(
        publisher: "Claude Code",
        target: "Work Room / deploy session / pane 42",
        verb: "Allow file write once",
        expires: nil,
        options: [],
        localAcknowledgmentAvailable: false,
        phase: .outcomeUnknown(transaction: "decision-0197"),
        decisionEnabled: false,
        presentation: ComposedPresentation(state: .stale, usability: .staleNonactionable),
        subject: PresentationSubject(
            componentName: "Publisher decision",
            target: "Work Room / deploy session / pane 42",
            reason: "Publisher response was lost",
            freshnessBucket: "12s ago"
        )
    )
}

#Preview("Permission ready") {
    PermissionView(
        state: PermissionPreviewFixture.ready,
        onDecision: { _ in },
        onAcknowledgeLocally: {},
        onCancelDispatch: {},
        onLookupOutcome: {},
        onRetry: {},
        dismissAndRestoreSource: {}
    )
    .allwardPalette(DesignPalette(appearance: .dark))
}

#Preview("Permission outcome unknown") {
    PermissionView(
        state: PermissionPreviewFixture.unknown,
        onDecision: { _ in },
        onAcknowledgeLocally: {},
        onCancelDispatch: {},
        onLookupOutcome: {},
        onRetry: {},
        dismissAndRestoreSource: {}
    )
    .allwardPalette(DesignPalette(appearance: .light))
}
