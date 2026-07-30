import AllwardConcierge
import AllwardCore
import AllwardDesign
import SwiftUI

@MainActor
public struct ConciergeView: View {
    private enum FocusTarget: Hashable {
        case dryRun
        case confirm
        case dismiss
    }

    @Environment(\.allwardPalette) private var palette
    @FocusState private var focus: FocusTarget?

    private let state: ConciergeViewState
    private let onDryRun: @MainActor () -> Void
    private let onConfirm: @MainActor () -> Void
    private let dismissAndRestoreSource: @MainActor () -> Void

    public init(
        state: ConciergeViewState,
        onDryRun: @escaping @MainActor () -> Void,
        onConfirm: @escaping @MainActor () -> Void,
        dismissAndRestoreSource: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onDryRun = onDryRun
        self.onConfirm = onConfirm
        self.dismissAndRestoreSource = dismissAndRestoreSource
    }

    public var body: some View {
        SurfacePanel(
            title: state.mode == .install ? "Install shell integration" : "Uninstall shell integration",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissAndRestoreSource,
            focusTitleOnAppear: false
        ) {
            conciergePresentationContent
        }
        .accessibilityLabel(accessibilityAnnouncement)
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        .onKeyPress(.escape) {
            dismissAndRestoreSource()
            return .handled
        }
        .task {
            focus = transactionEligible && state.plan != nil && !state.isApplying ? .dryRun : .dismiss
        }
    }

    @ViewBuilder
    private var conciergePresentationContent: some View {
        switch state.presentation.state {
        case .loading:
            LoadingStateView(
                target: state.subject.target,
                step: state.subject.boundedStep ?? "Preparing the shell integration plan",
                cancel: dismissAndRestoreSource
            )
        case .error:
            ErrorStateView(
                operation: state.subject.failedOperation ?? "Prepare shell integration",
                target: state.subject.target,
                cause: state.subject.reason ?? "The shell integration plan failed",
                recovery: state.subject.recovery ?? "Close and retry the exact host"
            )
        case .denied:
            status(
                presentationState: .denied,
                title: "Shell integration denied",
                detail: state.subject.reason ?? "Policy does not allow this shell integration change"
            )
            actionButton("Close", symbol: "xmark", focusTarget: .dismiss, action: dismissAndRestoreSource)
        case .empty, .live, .needsInput, .running, .finished, .stale, .degraded:
            laneTransactionContent
        }
    }

    private var laneTransactionContent: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            laneStatus
            if let plan = state.plan, transactionEligible {
                Divider().overlay(palette[.strokeDivider].swiftUIColor)
                exactPlan(plan)
                if state.isApplying {
                    status(
                        presentationState: .running,
                        title: state.mode == .install ? "Installing exact line" : "Removing exact line",
                        detail: plan.exactFile
                    )
                    actionButton(
                        "Close",
                        symbol: "xmark",
                        focusTarget: .dismiss,
                        action: dismissAndRestoreSource
                    )
                } else {
                    controls
                }
            } else if supportsRecipe {
                actionButton(
                    "Close",
                    symbol: "xmark",
                    focusTarget: .dismiss,
                    action: dismissAndRestoreSource
                )
            }
        }
    }

    @ViewBuilder
    private var laneStatus: some View {
        switch state.laneState {
        case .notInstalled:
            status(
                presentationState: .empty,
                title: "Shell integration is not installed",
                detail: "No Allward-owned shell line is recorded for this host"
            )
        case .installed:
            status(
                presentationState: .live,
                title: "Installed — awaiting first shell session",
                detail: recipeDetail
            )
        case .active:
            status(
                presentationState: .live,
                title: "Shell integration active",
                detail: recipeDetail
            )
        case let .stale(reason):
            status(
                presentationState: .stale,
                title: "Shell integration is stale",
                detail: reason.description
            )
        case let .unsupported(shell):
            status(
                presentationState: .degraded,
                title: "Shell integration is not yet supported for \(shell)",
                detail: "The lane-0 terminal remains available"
            )
            actionButton("Close", symbol: "xmark", focusTarget: .dismiss, action: dismissAndRestoreSource)
        }
    }

    private func exactPlan(_ plan: ShellIntegrationPlan) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Text(state.mode == .install ? "Planned addition" : "Planned removal")
                .tokenFont(.uiTitle, palette)
                .tokenForeground(.textPrimary, palette)
                .accessibilityAddTraits(.isHeader)
            fact(label: "Exact file", value: plan.exactFile)
            fact(label: "Exact single line", value: plan.exactLine)
            fact(
                label: state.mode == .install ? "Exact snippet file" : "Owned snippet file to remove",
                value: plan.snippetFile
            )
            fact(
                label: state.mode == .install ? "Exact snippet" : "Owned snippet to remove",
                value: plan.snippet
            )
            fact(label: "Recipe", value: "v\(plan.recipeVersion)")
        }
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            actionButton("Dry run", symbol: "doc.text.magnifyingglass", focusTarget: .dryRun, action: onDryRun)
            actionButton(
                state.mode == .install ? "Install exact line" : "Remove exact line",
                symbol: state.mode == .install ? "plus" : "minus",
                focusTarget: .confirm,
                action: onConfirm
            )
            .disabled(state.isApplying)
        }
    }

    private func status(
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
        .accessibilityValue("\(state.subject.target); \(detail)")
    }

    private func fact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Text(label)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
            Text(value)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .accessibilityLabel("\(label), \(value)")
        }
        .padding(SpaceToken.blockStandard.points)
        .background(palette[.surfaceRaised].swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
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
                .padding(.horizontal, SpaceToken.inlineStandard.points)
                .padding(.vertical, SpaceToken.blockCompact.points)
        }
        .buttonStyle(.plain)
        .background(palette[.surfaceRaised].swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
        .focused($focus, equals: focusTarget)
        .modifier(KeyboardFocusRing(isFocused: focus == focusTarget, palette: palette))
    }

    private var recipeDetail: String {
        guard let plan = state.plan else { return "Recorded recipe" }
        return "Recipe v\(plan.recipeVersion) · \(plan.exactFile)"
    }

    private var supportsRecipe: Bool {
        if case .unsupported = state.laneState { return false }
        return true
    }

    private var transactionEligible: Bool {
        switch (state.mode, state.laneState) {
        case (.install, .notInstalled):
            true
        case (.install, .stale(.recordedVersion(recorded: _, expected: _))):
            true
        case (.remove, .installed), (.remove, .active):
            true
        case (.remove, .stale(.recordedVersion(recorded: _, expected: _))):
            true
        default:
            false
        }
    }

    private var accessibilityAnnouncement: String {
        let action = state.mode == .install ? "Install" : "Uninstall"
        return "\(action), \(state.subject.target)"
    }
}

private enum ConciergePreviewFixture {
    static let plan = ShellIntegrationPlan(
        recipeVersion: ShellIntegrationRecipe.current.version,
        exactFile: "/Users/operator/.zshrc",
        exactLine: ShellIntegrationRecipe.current.rcLine,
        snippetFile: "/Users/operator/.config/allward/zsh-integration-v1.zsh",
        snippet: ShellIntegrationRecipe.current.snippet
    )

    static let install = ConciergeViewState(
        presentation: ComposedPresentation(state: .needsInput, usability: .usableActionCapable),
        subject: PresentationSubject(
            componentName: "Shell integration",
            target: "build-host · operator · zsh",
            verb: "Install",
            source: "Allward concierge"
        ),
        shell: "zsh",
        laneState: .notInstalled,
        plan: plan,
        mode: .install,
        isApplying: false
    )

    static let unsupported = ConciergeViewState(
        presentation: ComposedPresentation(
            state: .degraded,
            usability: .usableControlDisabled,
            controlDisabled: true
        ),
        subject: PresentationSubject(
            componentName: "Shell integration",
            target: "archive-host · operator · fish",
            capability: "supported shell recipe"
        ),
        shell: "fish",
        laneState: .unsupported(shell: "fish"),
        plan: nil,
        mode: .install,
        isApplying: false
    )
}

#Preview("Concierge install plan") {
    ConciergeView(
        state: ConciergePreviewFixture.install,
        onDryRun: {},
        onConfirm: {},
        dismissAndRestoreSource: {}
    )
    .allwardPalette(DesignPalette(appearance: .dark))
}

#Preview("Concierge unsupported shell") {
    ConciergeView(
        state: ConciergePreviewFixture.unsupported,
        onDryRun: {},
        onConfirm: {},
        dismissAndRestoreSource: {}
    )
    .allwardPalette(DesignPalette(appearance: .light))
}
