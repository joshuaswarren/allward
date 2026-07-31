import AllwardCore
import AllwardDesign
import AllwardRenderer
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
    /// A compact strip is one row of controls. Asking SwiftUI for a fitting
    /// height here returns a figure far larger than the row it draws, which
    /// silently steals rows from every terminal in the window.
    public static let height: CGFloat = 30

    public let tabs: [TabStripItem]
    public let selected: TabID?
    public let roomTint: TokenColor
    /// The strip frames the grid, so it is painted from the grid's own theme.
    /// Chrome colours follow the system appearance, which puts a white bar
    /// against a black terminal on a light-mode Mac. Every Mac terminal tints
    /// this area to the session background instead.
    public let theme: TerminalTheme
    public let onSelect: @MainActor (TabID) -> Void
    public let onClose: @MainActor (TabID) -> Void
    public let onNew: @MainActor () -> Void

    @Environment(\.allwardPalette) private var palette

    public init(
        tabs: [TabStripItem],
        selected: TabID?,
        roomTint: TokenColor,
        theme: TerminalTheme,
        onSelect: @escaping @MainActor (TabID) -> Void,
        onClose: @escaping @MainActor (TabID) -> Void,
        onNew: @escaping @MainActor () -> Void
    ) {
        self.tabs = tabs
        self.selected = selected
        self.roomTint = roomTint
        self.theme = theme
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
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height,
            alignment: .leading)
        .background(theme.defaultBackground.swiftUIColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(separator.swiftUIColor)
                .frame(height: StrokeToken.paneDivider.width(palette.settings))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// A tab lifts off the strip by a few percent of the foreground, the same
    /// way a terminal's own selection does, rather than by switching to a
    /// chrome colour that has nothing to do with the session.
    private var raisedSurface: TokenColor {
        theme.defaultBackground.mixed(with: theme.defaultForeground, amount: 0.2)
    }

    private var dimmedText: TokenColor {
        theme.defaultForeground.mixed(with: theme.defaultBackground, amount: 0.45)
    }

    private var separator: TokenColor {
        theme.defaultBackground.mixed(with: theme.defaultForeground, amount: 0.18)
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
            (isSelected ? theme.defaultForeground : dimmedText).swiftUIColor
        )
        .padding(.horizontal, SpaceToken.inlineStandard.points)
        .padding(.vertical, 3)
        .frame(maxWidth: 200)
        .background {
            RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                .fill(isSelected ? raisedSurface.swiftUIColor : Color.clear)
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
