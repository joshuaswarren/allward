import AllwardCore
import AllwardDesign
import SwiftUI

/// One tab as the strip needs it.
public struct TabStripItem: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    public var paneCount: Int

    public init(id: TabID, title: String, paneCount: Int) {
        self.id = id
        self.title = title
        self.paneCount = paneCount
    }
}

/// A compact tab strip. It appears only when a second tab exists, so a single
/// session keeps the grid as the whole window (DESIGN-LANGUAGE §23.1: chrome is
/// invisible until it carries something).
public struct TabStripView: View {
    public let tabs: [TabStripItem]
    public let selected: TabID?
    public let roomTint: TokenColor
    public let onSelect: @MainActor (TabID) -> Void
    public let onClose: @MainActor (TabID) -> Void
    public let onNew: @MainActor () -> Void

    @Environment(\.allwardPalette) private var palette

    public init(
        tabs: [TabStripItem],
        selected: TabID?,
        roomTint: TokenColor,
        onSelect: @escaping @MainActor (TabID) -> Void,
        onClose: @escaping @MainActor (TabID) -> Void,
        onNew: @escaping @MainActor () -> Void
    ) {
        self.tabs = tabs
        self.selected = selected
        self.roomTint = roomTint
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNew = onNew
    }

    public var body: some View {
        HStack(spacing: SpaceToken.inlineTight.points) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
            Button(action: onNew) {
                Image(systemName: "plus")
                    .imageScale(.small)
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .tokenForeground(.textSecondary, palette)
            .help("New tab")
            .accessibilityLabel("New tab")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpaceToken.inlineStandard.points)
        .padding(.vertical, SpaceToken.inlineTight.points)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette[.surface].swiftUIColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette[.strokeDivider].swiftUIColor)
                .frame(height: StrokeToken.paneDivider.width(palette.settings))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func tabButton(_ tab: TabStripItem) -> some View {
        let isSelected = tab.id == selected
        return HStack(spacing: SpaceToken.inlineTight.points) {
            Text(tab.title)
                .tokenFont(.uiLabel, palette)
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.paneCount > 1 {
                Text("\(tab.paneCount)")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
            }
            if tabs.count > 1 {
                Button { onClose(tab.id) } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .foregroundStyle(
            isSelected ? palette[.textPrimary].swiftUIColor : palette[.textSecondary].swiftUIColor
        )
        .padding(.horizontal, SpaceToken.inlineStandard.points)
        .padding(.vertical, 3)
        .frame(maxWidth: 200)
        .background {
            RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                .fill(
                    isSelected
                        ? palette[.surfaceRaised].swiftUIColor : Color.clear)
        }
        .overlay(alignment: .bottom) {
            // The Room tint marks the selected tab; identity stays legible
            // without hue because the selected tab also carries the raised
            // surface and the primary text colour.
            Rectangle()
                .fill(roomTint.swiftUIColor)
                .frame(height: 2)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tab.id) }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(tab.title)
    }
}
