import AllwardCore
import AllwardDesign
import SwiftUI

@MainActor
public struct DigestView: View {
    @Environment(\.allwardPalette) private var palette

    public let state: DigestViewState
    public let onOpenSource: @MainActor (RecordID) -> Void
    public let onCancelPreparation: @MainActor () -> Void
    public let onAcknowledge: @MainActor () -> Void
    public let onDismiss: @MainActor () -> Void

    public init(
        state: DigestViewState,
        onOpenSource: @escaping @MainActor (RecordID) -> Void = { _ in },
        onCancelPreparation: @escaping @MainActor () -> Void = {},
        onAcknowledge: @escaping @MainActor () -> Void = {},
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.onOpenSource = onOpenSource
        self.onCancelPreparation = onCancelPreparation
        self.onAcknowledge = onAcknowledge
        self.onDismiss = onDismiss
    }

    public var body: some View {
        SurfacePanel(
            title: "Digest",
            accessibilityTitle: "Digest, \(state.allowedUnseenEventCount) changes",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: onDismiss
        ) {
            VStack(alignment: .leading, spacing: SpaceToken.section.points) {
                facts
                    .accessibilitySortPriority(80)
                eventCount
                    .accessibilitySortPriority(10)
                stateDetail
                    .accessibilitySortPriority(20)
            }
        }
    }

    private var eventCount: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
            Text("\(state.allowedUnseenEventCount)")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
            Text(state.allowedUnseenEventCount == 1 ? "unseen change" : "unseen changes")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.allowedUnseenEventCount) unseen changes")
    }

    @ViewBuilder
    private var facts: some View {
        if !state.orderedFacts.isEmpty {
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                SectionHeader("Facts")
                    .accessibilityHidden(true)
                ForEach(state.orderedFacts) { fact in
                    factRow(fact)
                }
            }
        }
    }

    private func factRow(_ fact: DigestViewState.Fact) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
            HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
                StateBadge(presentation: fact.presentation, subject: fact.subject)
                Text("\(fact.roomName) / \(fact.sessionTitle)")
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(.textPrimary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(fact.target)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                FreshnessLabel(
                    age: fact.freshnessAge,
                    presentation: fact.presentation,
                    subject: fact.subject)
            }
            Text(fact.text)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textPrimary, palette)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onOpenSource(fact.sourceRecordID)
            } label: {
                HStack(spacing: SpaceToken.inlineStandard.points) {
                    Label(fact.sourceLabel, systemImage: "arrow.up.forward.square")
                        .tokenFont(.uiCaption, palette)
                    if let sourceCommandID = fact.sourceCommandID {
                        Text(sourceCommandID)
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textSecondary, palette)
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open source: \(fact.sourceLabel)")
            .accessibilityValue(fact.presentation.accessibilityValue(fact.subject))
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(fact.presentation.accessibilityValue(fact.subject))
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch state.state {
        case .preparing(let step, let cancellable):
            LoadingStateView(
                target: state.subject.target,
                step: step,
                cancel: cancellable ? onCancelPreparation : nil)
        case .readyDeterministic:
            digestActions
        case .readyRewritten(let prose):
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                SectionHeader("Summary")
                Text(prose)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                    .fixedSize(horizontal: false, vertical: true)
                digestActions
            }
        case .focusFiltered:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                Label("Filtered by Focus", systemImage: "line.3.horizontal.decrease.circle")
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(.textSecondary, palette)
                    .accessibilityHint("Only allowed Room facts and their event count are shown")
                digestActions
            }
        case .absent:
            HStack(spacing: SpaceToken.inlineStandard.points) {
                let mark = StateMark.mark(for: .empty)
                Label("Absent", systemImage: mark.symbolName)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(mark.color, palette)
                Text("No meaningful unseen changes")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        case .sourceStale(let reason):
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                let mark = StateMark.mark(for: .stale)
                Label("Source stale", systemImage: mark.symbolName)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(mark.color, palette)
                Text(reason)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
                digestActions
            }
        case .partialSourceError(let source, let cause):
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                ErrorStateView(
                    operation: "Read digest source",
                    target: source,
                    cause: cause,
                    recovery: "Available facts remain authoritative. Inspect the named source.")
                digestActions
            }
        case .acknowledged:
            HStack(spacing: SpaceToken.inlineStandard.points) {
                let mark = StateMark.mark(for: .finished)
                Label("Acknowledged", systemImage: mark.symbolName)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(mark.color, palette)
                Text("Saved in digest history")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
    }

    private var digestActions: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            Button("Acknowledge digest", action: onAcknowledge)
                .accessibilityValue(state.presentation.accessibilityValue(state.subject))
            Button("Close", action: onDismiss)
                .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        }
    }
}

#Preview("Digest rewritten") {
    DigestView(
        state: .fixture(
            state: .readyRewritten(
                prose: "Package checks completed, and checkout orchestration now needs your file-write decision.")))
        .frame(width: 680, height: 620)
        .padding(SpaceToken.section.points)
        .allwardPalette(DesignPalette(appearance: .dark))
}

#Preview("Digest partial source error") {
    DigestView(
        state: .fixture(
            state: .partialSourceError(
                source: "Fleet / jarvis", cause: "Direct SSH source disconnected during collection")))
        .frame(width: 680, height: 620)
        .padding(SpaceToken.section.points)
        .allwardPalette(DesignPalette(appearance: .light))
}
