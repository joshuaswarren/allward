import AllwardCore
import AllwardDesign
import AllwardMultiplexer
import SwiftUI

/// The facts a pane header presents, in the reading order fixed by
/// DESIGN-LANGUAGE §23.2. Nothing here may be model-generated urgency, an
/// unverified count, fabricated progress, or a capability inferred from
/// compositor pixels.
public struct PaneHeaderModel: Hashable, Sendable {
    public var roomName: String
    public var roomTint: TokenColor
    /// Shown only when the window context does not already make the Room clear.
    public var showsRoomIdentity: Bool
    public var sessionName: String
    public var host: String?
    public var workspace: String?
    public var paneLabel: String
    /// Coarse agent state from an adapter, or shell-region capability.
    public var agentState: AgentState?
    public var shellRegionsActive: Bool
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    /// A non-primary content route must name itself, permanently.
    public var routeDisclosure: String?
    public var staleReason: String?
    public var dictationLocked: Bool
    /// Present only while the router points at this pane.
    public var destinationKey: String?

    public init(
        roomName: String,
        roomTint: TokenColor,
        showsRoomIdentity: Bool,
        sessionName: String,
        host: String? = nil,
        workspace: String? = nil,
        paneLabel: String,
        agentState: AgentState? = nil,
        shellRegionsActive: Bool = false,
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        routeDisclosure: String? = nil,
        staleReason: String? = nil,
        dictationLocked: Bool = false,
        destinationKey: String? = nil
    ) {
        self.roomName = roomName
        self.roomTint = roomTint
        self.showsRoomIdentity = showsRoomIdentity
        self.sessionName = sessionName
        self.host = host
        self.workspace = workspace
        self.paneLabel = paneLabel
        self.agentState = agentState
        self.shellRegionsActive = shellRegionsActive
        self.presentation = presentation
        self.subject = subject
        self.routeDisclosure = routeDisclosure
        self.staleReason = staleReason
        self.dictationLocked = dictationLocked
        self.destinationKey = destinationKey
    }

    /// A single healthy pane keeps its identity in outer chrome; the band
    /// becomes persistent only when it carries something the user must see.
    public var mustPersist: Bool {
        presentation.state != .live || routeDisclosure != nil || staleReason != nil
            || dictationLocked || destinationKey != nil
    }
}

/// The reserved header band. Populating it never resizes the grid, because the
/// band is part of the same geometry transaction as the split (§23.1).
public struct PaneHeaderView: View {
    public let model: PaneHeaderModel
    public let isFocused: Bool
    @Environment(\.allwardPalette) private var palette

    public init(model: PaneHeaderModel, isFocused: Bool) {
        self.model = model
        self.isFocused = isFocused
    }

    public var body: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            if model.showsRoomIdentity {
                roomIdentity
                Divider().frame(height: 11)
            }
            Text(model.sessionName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)

            provenance

            Spacer(minLength: SpaceToken.inlineStandard.points)

            if let agentState = model.agentState { AgentStateChip(state: agentState) }
            if model.shellRegionsActive { capabilityChip("Shell regions") }
            if let disclosure = model.routeDisclosure { disclosureChip(disclosure) }
            if model.dictationLocked { dictationChip }
            stateBadge
            if let key = model.destinationKey { destinationCap(key) }
        }
        .padding(.horizontal, SpaceToken.inlineStandard.points)
        .padding(.vertical, SpaceToken.blockCompact.points)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette[.surface].swiftUIColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(model.roomTint.swiftUIColor)
                .frame(width: StrokeToken.roomSeam.width(palette.settings))
                .opacity(isFocused ? 1 : 0.45)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette[.strokeDivider].swiftUIColor)
                .frame(height: StrokeToken.paneDivider.width(palette.settings))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.sessionName)
        .accessibilityValue(model.presentation.accessibilityValue(model.subject))
    }

    private var roomIdentity: some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(model.roomTint.swiftUIColor)
                .frame(width: 6, height: 6)
            Text(model.roomName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
        }
        .accessibilityLabel("Room \(model.roomName)")
    }

    /// Host, workspace and pane identity keep their distinguishing segment when
    /// space runs out; the full value stays in the accessibility label.
    private var provenance: some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            ForEach(provenanceParts, id: \.self) { part in
                Text(part)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .accessibilityLabel(provenanceParts.joined(separator: ", "))
    }

    private var provenanceParts: [String] {
        var parts: [String] = []
        if let host = model.host { parts.append(host) }
        if let workspace = model.workspace { parts.append(workspace) }
        parts.append(model.paneLabel)
        return parts
    }

    private var stateBadge: some View {
        let mark = StateMark.mark(for: model.presentation.state)
        return HStack(spacing: SpaceToken.inlineTight.points) {
            Image(systemName: mark.symbolName)
                .imageScale(.small)
            Text(model.staleReason ?? mark.label)
                .tokenFont(.uiCaption, palette)
        }
        .foregroundStyle(palette[mark.color].swiftUIColor)
        .accessibilityHidden(true)
    }

    private var dictationChip: some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            Image(systemName: "waveform").imageScale(.small)
            Text("Dictating").tokenFont(.uiCaption, palette)
        }
        .foregroundStyle(palette[.stateRunning].swiftUIColor)
        .accessibilityLabel("Dictation locked to this pane")
    }

    private func capabilityChip(_ text: String) -> some View {
        Text(text)
            .tokenFont(.uiCaption, palette)
            .tokenForeground(.textSecondary, palette)
            .padding(.horizontal, SpaceToken.inlineTight.points)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                    .fill(palette[.surfaceRaised].swiftUIColor))
    }

    private func disclosureChip(_ text: String) -> some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            Image(systemName: "arrow.down.right.circle").imageScale(.small)
            Text(text).tokenFont(.uiCaption, palette)
        }
        .foregroundStyle(palette[.stateStale].swiftUIColor)
        .accessibilityLabel(text)
    }

    private func destinationCap(_ key: String) -> some View {
        Text(key)
            .tokenFont(.uiData, palette)
            .tokenForeground(.textPrimary, palette)
            .padding(.horizontal, SpaceToken.inlineTight.points)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(model.roomTint.swiftUIColor.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(model.roomTint.swiftUIColor, lineWidth: 1)
            )
            .accessibilityLabel("Destination key \(key)")
    }
}

/// Coarse adapter-reported agent state. Never inferred from terminal pixels.
struct AgentStateChip: View {
    let state: AgentState
    @Environment(\.allwardPalette) private var palette

    var body: some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            Image(systemName: symbol).imageScale(.small)
            Text(label).tokenFont(.uiCaption, palette)
        }
        .foregroundStyle(palette[color].swiftUIColor)
        .accessibilityLabel("Agent \(label)")
    }

    private var label: String {
        switch state {
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    private var symbol: String {
        switch state {
        case .working: "circle.dotted.circle"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: ColorToken {
        switch state {
        case .working: .stateRunning
        case .blocked: .stateNeedsInput
        case .done: .stateFinished
        case .idle: .stateIdle
        case .unknown: .textSecondary
        }
    }
}
