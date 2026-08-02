import AllwardConfig
import AllwardCore
import AllwardDesign
import AllwardSurfaces
import SwiftUI

@MainActor
public struct RouterStripView: View {
    @Environment(\.allwardPalette) private var palette

    public let state: RouterViewState
    /// What the last action had to say. Shown here because an action that
    /// refuses and says nothing is indistinguishable from one that is broken.
    public let message: String?
    public let onOpenBoard: @MainActor () -> Void

    public init(
        state: RouterViewState,
        message: String? = nil,
        onOpenBoard: @escaping @MainActor () -> Void = {},
    ) {
        self.message = message
        self.state = state
        self.onOpenBoard = onOpenBoard
    }

    /// Whether the strip belongs on screen.
    ///
    /// DESIGN-LANGUAGE §23.5 keeps it away when nothing is actionable, because
    /// a permanent "no actionable items" band earns nothing. A message is the
    /// exception: it is the only place the application can answer for an
    /// action, and it clears itself.
    public static func isVisible(
        actionableCount: Int, hasItems: Bool, message: String?,
        preference: AttentionBarVisibility = .automatic
    ) -> Bool {
        switch preference {
        case .hidden: false
        case .always: true
        case .automatic: actionableCount > 0 || hasItems || message != nil
        }
    }

    /// Context, then status, then the way out.
    ///
    /// This read `● 3 Personal 12m 1` - a mark, a bare number before any word
    /// that says what it counts, the Room, a duration, and a loose digit - in
    /// four different type tokens (`.uiData`, `.uiRoom`, `.uiCaption`,
    /// `.uiLabel`) across twenty points of height. Now it answers three
    /// questions in the order anyone asks them: where am I, what wants me, and
    /// how do I get to it. Two tokens only: one you read, one that stays out of
    /// the way.
    public var body: some View {
        HStack(spacing: SpaceToken.blockStandard.points) {
            RoomSeam(roomTint: state.roomTint)
            Text(state.roomName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(state.roomName)
            stripContent
            if let detail = secondaryDetail {
                Text(detail)
                    .tokenFont(.uiCaption, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SpaceToken.inlineStandard.points)
            boardCommand
        }
        .padding(.horizontal, SpaceToken.blockStandard.points)
        .padding(.vertical, SpaceToken.blockCompact.points)
        .background(palette[palette.resolve(.chromeBase).baseColor].swiftUIColor)
        .overlay(alignment: .top) {
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
        if let message {
            Label(message, systemImage: StateMark.mark(for: .needsInput).symbolName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(StateMark.mark(for: .needsInput).color, palette)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(message)
        } else if state.presentation.state == .loading {
            Label(
                state.subject.boundedStep ?? "Looking for sessions",
                systemImage: StateMark.mark(for: .loading).symbolName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
                .lineLimit(1)
        } else if state.zeroState != .none || state.actionableCount == 0 {
            Label("Nothing needs you", systemImage: StateMark.mark(for: .empty).symbolName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
        } else {
            attentionSummary
        }
    }

    /// A count is only useful beside the word for what it counts.
    private var attentionSummary: some View {
        let mark = StateMark.mark(for: attentionPresentationState)
        let noun = state.actionableCount == 1 ? "session needs" : "sessions need"
        let label = Label(
            "\(state.actionableCount) \(noun) you", systemImage: mark.symbolName)
            .tokenFont(.uiLabel, palette)
            .tokenForeground(mark.color, palette)
            .accessibilityLabel(countAccessibilityLabel)
        return Group {
            if palette.settings.reduceMotion || state.highestClass == .stale
                || state.newEpochs.isEmpty
            {
                label
            } else {
                label
                    .symbolEffect(.pulse, options: .nonRepeating, value: state.newEpochs.last)
                    .animation(
                        .easeInOut(duration: MotionToken.routerPulse.duration(reduceMotion: false)),
                        value: state.newEpochs.last)
            }
        }
    }

    /// Everything that qualifies the status, in one dim phrase rather than
    /// three competing ones.
    private var secondaryDetail: String? {
        guard message == nil else { return nil }
        var parts: [String] = []
        if state.presentation.state == .degraded { parts.append(degradedDetail) }
        if state.focusFiltered { parts.append("Focus is filtering") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                Text(Shortcut.board.display)
                    .tokenFont(.uiCaption, palette)
                    .tokenForeground(.textSecondary, palette)
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
