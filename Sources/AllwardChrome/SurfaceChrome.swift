import AllwardCore
import AllwardDesign
import Foundation
import SwiftUI

@MainActor
public struct StateBadge: View {
    @Environment(\.allwardPalette) private var palette

    public let presentation: ComposedPresentation
    public let subject: PresentationSubject

    public init(presentation: ComposedPresentation, subject: PresentationSubject) {
        self.presentation = presentation
        self.subject = subject
    }

    public var body: some View {
        let mark = StateMark.mark(for: presentation.state)
        Label(mark.label, systemImage: mark.symbolName)
            .labelStyle(.titleAndIcon)
            .tokenFont(.uiLabel, palette)
            .tokenForeground(mark.color, palette)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mark.label)
            .accessibilityValue(presentation.accessibilityValue(subject))
    }
}

@MainActor
public struct FreshnessLabel: View {
    @Environment(\.allwardPalette) private var palette

    public let age: TimeInterval
    public let presentation: ComposedPresentation
    public let subject: PresentationSubject

    public init(
        age: TimeInterval,
        presentation: ComposedPresentation,
        subject: PresentationSubject
    ) {
        self.age = max(0, age)
        self.presentation = presentation
        self.subject = subject
    }

    public var body: some View {
        let mark = StateMark.mark(for: presentation.state)
        let bucket = FreshnessBucket.bucket(forAge: age)
        HStack(spacing: SpaceToken.inlineTight.points) {
            Image(systemName: mark.symbolName)
                .accessibilityHidden(true)
            Text(bucket.label(forAge: age))
                .lineLimit(1)
        }
        .tokenFont(.uiData, palette)
        .tokenForeground(.textSecondary, palette)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Freshness")
        .accessibilityValue(
            "\(bucket.label(forAge: age)); \(presentation.accessibilityValue(subject))")
    }
}

@MainActor
public struct DestinationKeyCap: View {
    @Environment(\.allwardPalette) private var palette

    public let key: String
    public let target: String

    public init(key: String, target: String) {
        self.key = key
        self.target = target
    }

    public var body: some View {
        Text("\(key)")
            .tokenFont(.uiData, palette)
            .tokenForeground(.textPrimary, palette)
            .padding(.horizontal, SpaceToken.inlineStandard.points)
            .padding(.vertical, SpaceToken.inlineTight.points)
            .background(palette[.surface].swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                    .strokeBorder(
                        palette[.strokeDivider].swiftUIColor,
                        lineWidth: StrokeToken.paneDivider.width(palette.settings))
            }
            .accessibilityLabel("Destination \(key)")
            .accessibilityValue(target)
    }
}

@MainActor
public struct RoomSeam: View {
    @Environment(\.allwardPalette) private var palette

    public let roomTint: TokenColor

    public init(roomTint: TokenColor) {
        self.roomTint = roomTint
    }

    public var body: some View {
        let roomPalette = DesignPalette(
            appearance: palette.appearance,
            settings: palette.settings,
            contentSize: palette.contentSize,
            roomTint: roomTint)
        Rectangle()
            .fill(roomPalette[.seam].swiftUIColor)
            .frame(width: StrokeToken.roomSeam.width(palette.settings))
            .accessibilityHidden(true)
    }
}

@MainActor
public struct SectionHeader: View {
    @Environment(\.allwardPalette) private var palette

    public let title: String
    public let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
            Text(title)
                .tokenFont(.uiRoom, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .accessibilityLabel("\(count) items")
            }
            Spacer(minLength: SpaceToken.inlineStandard.points)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
public struct EmptyStateView: View {
    @Environment(\.allwardPalette) private var palette

    public let title: String
    public let reason: String
    public let actionTitle: String?
    public let action: (@MainActor () -> Void)?

    public init(
        title: String,
        reason: String,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.reason = reason
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Label("Empty", systemImage: StateMark.mark(for: .empty).symbolName)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
            Text(title)
                .tokenFont(.uiTitle, palette)
                .tokenForeground(.textPrimary, palette)
            Text(reason)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityValue(reason)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
public struct ErrorStateView: View {
    @Environment(\.allwardPalette) private var palette

    public let operation: String
    public let target: String
    public let cause: String
    public let recovery: String
    public let retry: (@MainActor () -> Void)?

    public init(
        operation: String,
        target: String,
        cause: String,
        recovery: String,
        retry: (@MainActor () -> Void)? = nil
    ) {
        self.operation = operation
        self.target = target
        self.cause = cause
        self.recovery = recovery
        self.retry = retry
    }

    public var body: some View {
        let mark = StateMark.mark(for: .error)
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Label("Error", systemImage: mark.symbolName)
                .tokenFont(.uiTitle, palette)
                .tokenForeground(mark.color, palette)
                .accessibilityAddTraits(.isHeader)
            Text(target)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
            Text("\(operation): \(cause)")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textPrimary, palette)
            Text(recovery)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            if let retry {
                Button("Retry", action: retry)
                    .accessibilityValue("Error: \(target); \(operation); \(recovery)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Error: \(target); \(operation); \(recovery)")
    }
}

@MainActor
public struct LoadingStateView: View {
    @Environment(\.allwardPalette) private var palette

    public let target: String
    public let step: String
    public let cancel: (@MainActor () -> Void)?

    public init(
        target: String,
        step: String,
        cancel: (@MainActor () -> Void)? = nil
    ) {
        self.target = target
        self.step = step
        self.cancel = cancel
    }

    public var body: some View {
        let mark = StateMark.mark(for: .loading)
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            Label("Loading", systemImage: mark.symbolName)
                .tokenFont(.uiTitle, palette)
                .tokenForeground(mark.color, palette)
            Text(target)
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textPrimary, palette)
            Text(step)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            if let cancel {
                Button("Cancel", action: cancel)
                    .accessibilityValue("Loading: \(target); \(step)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Loading: \(target); \(step)")
    }
}

@MainActor
public struct SurfacePanel<Content: View>: View {
    @Environment(\.allwardPalette) private var palette
    @AccessibilityFocusState private var titleFocused: Bool
    @FocusState private var panelFocused: Bool

    public let title: String
    public let accessibilityTitle: String?
    public let presentation: ComposedPresentation?
    public let subject: PresentationSubject?
    public let onDismiss: @MainActor () -> Void
    public let focusTitleOnAppear: Bool
    private let content: Content

    public init(
        title: String,
        accessibilityTitle: String? = nil,
        presentation: ComposedPresentation? = nil,
        subject: PresentationSubject? = nil,
        onDismiss: @escaping @MainActor () -> Void = {},
        focusTitleOnAppear: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityTitle = accessibilityTitle
        self.presentation = presentation
        self.subject = subject
        self.onDismiss = onDismiss
        self.focusTitleOnAppear = focusTitleOnAppear
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
                Text(title)
                    .tokenFont(.uiTitle, palette)
                    .tokenForeground(.textPrimary, palette)
                    .accessibilityLabel(accessibilityTitle ?? title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(100)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                if let presentation, let subject, presentation.state != .live {
                    StateBadge(presentation: presentation, subject: subject)
                        .accessibilitySortPriority(-1)
                }
            }
            Divider()
                .overlay(palette[.strokeDivider].swiftUIColor)
            content
        }
        .padding(SpaceToken.section.points)
        .background(materialColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.panel.points, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RadiusToken.panel.points, style: .continuous)
                .strokeBorder(
                    palette[.strokeDivider].swiftUIColor,
                    lineWidth: StrokeToken.paneDivider.width(palette.settings))
        }
        .focusable(focusTitleOnAppear)
        .focused($panelFocused)
        .focusEffectDisabled()
        .onAppear {
            if focusTitleOnAppear {
                titleFocused = true
                panelFocused = true
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var materialColor: Color {
        palette[palette.resolve(.chromeRaised).baseColor].swiftUIColor
    }
}

#Preview("Surface panel") {
    let fixture = BoardViewState.fixture()
    SurfacePanel(
        title: "Board",
        presentation: fixture.presentation,
        subject: fixture.subject
    ) {
        EmptyStateView(
            title: "No sessions yet",
            reason: "Create a local terminal, connect SSH, or choose a configured adapter.")
    }
    .frame(width: 520)
    .padding(SpaceToken.section.points)
    .allwardPalette(DesignPalette(appearance: .dark))
}
