import AllwardDesign
import SwiftUI

/// Find across a session's scrollback.
///
/// Every terminal has this and Allward did not, which made anything that had
/// scrolled away unreachable without a pointer and a lot of squinting.
public struct FindView: View {
    public let matchCount: Int
    public let currentMatch: Int
    public let onQueryChanged: @MainActor (String) -> Void
    public let onNext: @MainActor () -> Void
    public let onPrevious: @MainActor () -> Void
    public let onDismiss: @MainActor () -> Void

    @Environment(\.allwardPalette) private var palette
    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    public init(
        matchCount: Int,
        currentMatch: Int,
        onQueryChanged: @escaping @MainActor (String) -> Void,
        onNext: @escaping @MainActor () -> Void,
        onPrevious: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.matchCount = matchCount
        self.currentMatch = currentMatch
        self.onQueryChanged = onQueryChanged
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            Image(systemName: "magnifyingglass")
                .tokenForeground(.textSecondary, palette)
            TextField("Find in scrollback", text: $query)
                .textFieldStyle(.plain)
                .tokenFont(.uiBody, palette)
                .focused($fieldFocused)
                .onChange(of: query) { _, value in onQueryChanged(value) }
                .onSubmit(onNext)
            Text(tally)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel(tally)
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .accessibilityLabel("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .accessibilityLabel("Next match")
        }
        .padding(.horizontal, SpaceToken.blockStandard.points)
        .padding(.vertical, SpaceToken.inlineStandard.points)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: RadiusToken.panel.points, style: .continuous)
                .fill(palette[.surfaceRaised].swiftUIColor))
        .overlay(
            RoundedRectangle(cornerRadius: RadiusToken.panel.points, style: .continuous)
                .stroke(palette[.strokeDivider].swiftUIColor, lineWidth: 1))
        .onAppear { fieldFocused = true }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    /// Says nothing until there is something to say, then counts honestly.
    private var tally: String {
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No matches" }
        return "\(currentMatch + 1) of \(matchCount)"
    }
}
