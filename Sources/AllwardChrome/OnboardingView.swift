import AllwardCore
import AllwardDesign
import SwiftUI

public struct OnboardingAction: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var shortcut: String
    public var symbol: String

    public init(id: String, title: String, shortcut: String, symbol: String) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.symbol = symbol
    }
}

public struct OnboardingStep: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String
    public var actions: [OnboardingAction]

    public init(id: String, title: String, explanation: String, actions: [OnboardingAction]) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.actions = actions
    }
}

public struct OnboardingViewState: Hashable, Sendable {
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var steps: [OnboardingStep]
    public var currentStepIndex: Int

    public init(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        steps: [OnboardingStep],
        currentStepIndex: Int
    ) {
        self.presentation = presentation
        self.subject = subject
        self.steps = steps
        self.currentStepIndex = currentStepIndex
    }

    public static func fixture(currentStepIndex: Int = 0) -> OnboardingViewState {
        OnboardingViewState(
            presentation: ComposedPresentation(state: .live, usability: .usableActionCapable),
            subject: PresentationSubject(componentName: "First run", target: "Allward workspace"),
            steps: [
                OnboardingStep(
                    id: "room",
                    title: "Choose a Room",
                    explanation: "A Room keeps one work context together: its windows, hosts, "
                        + "theme, and notification rules.",
                    actions: [
                        OnboardingAction(
                            id: "choose-room",
                            title: "Open Room switcher",
                            shortcut: "⌘⇧M",
                            symbol: "rectangle.3.group"
                        )
                    ]
                ),
                OnboardingStep(
                    id: "terminal",
                    title: "Open a terminal",
                    explanation: "Start a local terminal or connect one of your configured SSH hosts. "
                        + "Neither path needs an adapter.",
                    actions: [
                        OnboardingAction(
                            id: "new-local-terminal",
                            title: "New local terminal",
                            shortcut: "⌘T",
                            symbol: "terminal"
                        ),
                        OnboardingAction(
                            id: "connect-ssh",
                            title: "Connect SSH host",
                            shortcut: "⌘⇧O",
                            symbol: "network"
                        )
                    ]
                ),
                OnboardingStep(
                    id: "board",
                    title: "Find the board",
                    explanation: "The board lists sessions and open attention across Rooms "
                        + "without replacing terminal output.",
                    actions: [
                        OnboardingAction(
                            id: "open-board",
                            title: "Open board",
                            shortcut: "⌘⇧B",
                            symbol: "rectangle.grid.1x2"
                        )
                    ]
                )
            ],
            currentStepIndex: currentStepIndex
        )
    }
}

@MainActor
public struct OnboardingView: View {
    @Environment(\.allwardPalette) private var palette
    @State private var currentStepIndex: Int
    @FocusState private var focusedActionID: String?

    private let state: OnboardingViewState
    private let onPerform: @MainActor (OnboardingAction) -> Void
    private let dismissForNow: @MainActor () -> Void
    private let dismissForever: @MainActor () -> Void

    public init(
        state: OnboardingViewState,
        onPerform: @escaping @MainActor (OnboardingAction) -> Void,
        dismissForNow: @escaping @MainActor () -> Void,
        dismissForever: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onPerform = onPerform
        self.dismissForNow = dismissForNow
        self.dismissForever = dismissForever
        _currentStepIndex = State(initialValue: state.currentStepIndex)
    }

    public var body: some View {
        SurfacePanel(
            title: "First run",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissForNow,
            focusTitleOnAppear: false
        ) {
            onboardingPresentationContent
        }
        .accessibilityLabel("First run")
        .accessibilityValue(
            currentStep.map {
                "Step \(displayStepNumber) of \(state.steps.count), \($0.title)"
            } ?? "Empty"
        )
        .onKeyPress(.escape) {
            dismissForNow()
            return .handled
        }
        .task {
            focusedActionID = currentStep?.actions.first?.id
        }
        .onChange(of: currentStepIndex) {
            focusedActionID = currentStep?.actions.first?.id
        }
    }

    @ViewBuilder
    private var onboardingPresentationContent: some View {
        switch state.presentation.state {
        case .loading:
            LoadingStateView(
                target: state.subject.target,
                step: state.subject.boundedStep ?? "Preparing first-run actions",
                cancel: dismissForNow
            )
        case .empty:
            EmptyStateView(
                title: "Onboarding unavailable",
                reason: state.subject.reason ?? "No first-run steps were provided"
            )
        case .error:
            ErrorStateView(
                operation: state.subject.failedOperation ?? "Prepare first run",
                target: state.subject.target,
                cause: state.subject.reason ?? "First-run actions failed to load",
                recovery: state.subject.recovery ?? "Dismiss and open the command palette"
            )
        case .live:
            liveOnboarding
        case .needsInput, .running, .finished, .stale, .degraded, .denied:
            nonLiveOnboarding
        }
    }

    private var liveOnboarding: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            stepCounter
            if let step = currentStep {
                stepContent(step)
            } else {
                EmptyStateView(
                    title: "Onboarding unavailable",
                    reason: "No first-run steps were provided"
                )
            }
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
            footer
        }
    }

    private var nonLiveOnboarding: some View {
        let mark = StateMark.mark(for: state.presentation.state)
        return HStack(alignment: .top, spacing: SpaceToken.inlineStandard.points) {
            Image(systemName: mark.symbolName)
                .tokenForeground(mark.color, palette)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                Text(mark.label)
                    .tokenFont(.uiTitle, palette)
                    .tokenForeground(.textPrimary, palette)
                Text(state.subject.reason ?? "First-run actions are unavailable in the current state")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
    }

    private var stepCounter: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            Text("Step \(displayStepNumber) of \(state.steps.count)")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textSecondary, palette)
            Spacer(minLength: SpaceToken.inlineStandard.points)
            ForEach(state.steps.indices, id: \.self) { index in
                Image(systemName: index == boundedStepIndex ? "circle.fill" : "circle")
                    .tokenForeground(index == boundedStepIndex ? .textPrimary : .textDisabled, palette)
                    .accessibilityHidden(true)
            }
        }
    }

    private func stepContent(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Text(step.title)
                .tokenFont(.uiRoom, palette)
                .tokenForeground(.textPrimary, palette)
                .accessibilityAddTraits(.isHeader)
            Text(step.explanation)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            ForEach(step.actions) { action in
                Button {
                    onPerform(action)
                } label: {
                    HStack(spacing: SpaceToken.inlineStandard.points) {
                        Label(action.title, systemImage: action.symbol)
                            .tokenFont(.uiBody, palette)
                        Spacer(minLength: SpaceToken.inlineStandard.points)
                        Text(action.shortcut)
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textSecondary, palette)
                    }
                    .padding(.horizontal, SpaceToken.inlineStandard.points)
                    .padding(.vertical, SpaceToken.blockCompact.points)
                }
                .buttonStyle(.plain)
                .background(palette[.surfaceRaised].swiftUIColor)
                .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
                .focused($focusedActionID, equals: action.id)
                .modifier(KeyboardFocusRing(isFocused: focusedActionID == action.id, palette: palette))
                .accessibilityLabel(action.title)
                .accessibilityValue("Keyboard shortcut \(action.shortcut)")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            Button("Don’t show this again", action: dismissForever)
                .tokenFont(.uiBody, palette)
                .accessibilityHint("Permanently dismisses first-run guidance")
            Spacer(minLength: SpaceToken.inlineStandard.points)
            Button("Back") {
                currentStepIndex = max(0, boundedStepIndex - 1)
            }
            .disabled(boundedStepIndex == 0)
            if boundedStepIndex + 1 < state.steps.count {
                Button("Next") {
                    currentStepIndex = min(state.steps.count - 1, boundedStepIndex + 1)
                }
            } else {
                Button("Done", action: dismissForNow)
            }
        }
        .tokenFont(.uiBody, palette)
    }

    private var boundedStepIndex: Int {
        guard !state.steps.isEmpty else { return 0 }
        return min(max(currentStepIndex, 0), state.steps.count - 1)
    }

    private var displayStepNumber: Int {
        state.steps.isEmpty ? 0 : boundedStepIndex + 1
    }

    private var currentStep: OnboardingStep? {
        guard !state.steps.isEmpty else { return nil }
        return state.steps[boundedStepIndex]
    }
}

#Preview("First run — Room") {
    OnboardingView(
        state: .fixture(currentStepIndex: 0),
        onPerform: { _ in },
        dismissForNow: {},
        dismissForever: {}
    )
    .allwardPalette(DesignPalette(appearance: .dark))
}

#Preview("First run — Board") {
    OnboardingView(
        state: .fixture(currentStepIndex: 2),
        onPerform: { _ in },
        dismissForNow: {},
        dismissForever: {}
    )
    .allwardPalette(DesignPalette(appearance: .light))
}
