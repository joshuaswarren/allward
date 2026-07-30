import AllwardCore
import AllwardDesign
import AllwardSurfaces
import SwiftUI

@MainActor
public struct RouterStripView: View {
    @Environment(\.allwardPalette) private var palette

    public let state: RouterViewState
    public let onOpenBoard: @MainActor () -> Void
    public let onOpenDestination: @MainActor (String) -> Void

    public init(
        state: RouterViewState,
        onOpenBoard: @escaping @MainActor () -> Void = {},
        onOpenDestination: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.state = state
        self.onOpenBoard = onOpenBoard
        self.onOpenDestination = onOpenDestination
    }

    public var body: some View {
        HStack(spacing: SpaceToken.blockStandard.points) {
            RoomSeam(roomTint: state.roomTint)
            stripContent
            Spacer(minLength: SpaceToken.inlineStandard.points)
            boardCommand
        }
        .padding(.horizontal, SpaceToken.blockStandard.points)
        .padding(.vertical, SpaceToken.blockCompact.points)
        .background(palette[palette.resolve(.chromeBase).baseColor].swiftUIColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette[.strokeDivider].swiftUIColor)
                .frame(height: StrokeToken.paneDivider.width(palette.settings))
        }
        .focusable(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
    }

    @ViewBuilder
    private var stripContent: some View {
        if state.presentation.state == .loading {
            loadingContent
        } else if state.zeroState != .none || state.actionableCount == 0 {
            zeroContent
        } else {
            activeContent
        }
    }

    private var loadingContent: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            StateBadge(presentation: state.presentation, subject: state.subject)
            Text(state.subject.target)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(state.subject.target)
            Text(state.subject.boundedStep ?? "First-value attempt in progress")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textSecondary, palette)
        }
    }

    private var zeroContent: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            let mark = StateMark.mark(for: .empty)
            Label("No actionable items", systemImage: mark.symbolName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
            Text(state.roomName)
                .tokenFont(.uiRoom, palette)
                .tokenForeground(.textPrimary, palette)
        }
    }

    private var activeContent: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            pulseMark
            Text("\(state.actionableCount)")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .accessibilityLabel(countAccessibilityLabel)
            Text(state.roomName)
                .tokenFont(.uiRoom, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(state.roomName)
            if state.presentation.state == .degraded {
                Text(degradedDetail)
                    .tokenFont(.uiCaption, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(degradedDetail)
            }
            FreshnessLabel(
                age: state.freshnessAge,
                presentation: state.presentation,
                subject: state.subject)
            if let destinationKey = state.destinationKey {
                Button {
                    onOpenDestination(destinationKey)
                } label: {
                    DestinationKeyCap(key: destinationKey, target: state.subject.target)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityValue(state.presentation.accessibilityValue(state.subject))
            }
            if state.focusFiltered {
                Label("Filtered by Focus", systemImage: "line.3.horizontal.decrease.circle")
                    .tokenFont(.uiCaption, palette)
                    .tokenForeground(.textSecondary, palette)
                    .help(
                        "Only attention allowed by the current Focus policy is counted. "
                            + "Open Board to inspect policy.")
                    .accessibilityHint("Open Board to inspect the current Focus policy")
            }
        }
    }

    @ViewBuilder
    private var pulseMark: some View {
        let presentationState = attentionPresentationState
        let mark = StateMark.mark(for: presentationState)
        let label = Label(mark.label, systemImage: mark.symbolName)
            .tokenFont(.uiLabel, palette)
            .tokenForeground(mark.color, palette)
            .accessibilityLabel(mark.label)
        if palette.settings.reduceMotion || state.highestClass == .stale || state.newEpochs.isEmpty {
            label
        } else {
            label
                .symbolEffect(.pulse, options: .nonRepeating, value: state.newEpochs.last)
                .animation(
                    .easeInOut(duration: MotionToken.routerPulse.duration(reduceMotion: false)),
                    value: state.newEpochs.last)
        }
    }

    private var countAccessibilityLabel: String {
        state.highestClass == .stale
            ? "\(state.actionableCount) stale"
            : "\(state.actionableCount) actionable"
    }

    private var degradedDetail: String {
        let provenance = state.items.first?.provenanceLabel ?? "Source"
        let capability = state.subject.capability ?? "capability"
        return "\(provenance) • Missing \(capability)"
    }

    private var boardCommand: some View {
        Button(action: onOpenBoard) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text("Board")
                    .tokenFont(.uiLabel, palette)
                Text("⌘⇧B")
                    .tokenFont(.uiData, palette)
            }
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .accessibilityLabel("Open Board")
        .accessibilityValue("Keyboard shortcut Command Shift B")
    }

    private var attentionPresentationState: PresentationState {
        switch state.highestClass {
        case .needsInput: .needsInput
        case .error: .error
        case .finished: .finished
        case .running: .running
        case .stale: .stale
        case nil: state.presentation.state
        }
    }

    private var accessibilityLabel: String {
        if state.actionableCount == 0 {
            return "Router, no actionable items, Board shortcut Command Shift B"
        }
        let filter = state.focusFiltered ? ", filtered by Focus" : ""
        return "Router, \(state.actionableCount) actionable, \(state.roomName)\(filter)"
    }
}

#Preview("Router needs input") {
    VStack(spacing: SpaceToken.section.points) {
        RouterStripView(state: .fixture())
        RouterStripView(state: .fixture(focusFiltered: true))
        RouterStripView(state: .fixture(zeroState: .zeroPublishers))
    }
    .frame(width: 900)
    .padding(SpaceToken.section.points)
    .background(DesignPalette(appearance: .dark)[.canvas].swiftUIColor)
    .allwardPalette(DesignPalette(appearance: .dark))
}
