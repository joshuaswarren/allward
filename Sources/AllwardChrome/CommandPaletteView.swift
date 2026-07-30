import AllwardCore
import AllwardDesign
import Foundation
import SwiftUI

@MainActor
public struct CommandPaletteView: View {
    private enum FocusTarget: Hashable {
        case query
        case command(String)
    }

    @Environment(\.allwardPalette) private var palette
    @FocusState private var focus: FocusTarget?
    @State private var query: String
    @State private var selectedCommandID: String?

    private let state: CommandPaletteViewState
    private let onQueryChanged: @MainActor (String) -> Void
    private let onSubmit: @MainActor (PaletteCommand) -> Void
    private let dismissAndRestoreInvocation: @MainActor () -> Void

    public init(
        state: CommandPaletteViewState,
        onQueryChanged: @escaping @MainActor (String) -> Void,
        onSubmit: @escaping @MainActor (PaletteCommand) -> Void,
        dismissAndRestoreInvocation: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onQueryChanged = onQueryChanged
        self.onSubmit = onSubmit
        self.dismissAndRestoreInvocation = dismissAndRestoreInvocation
        _query = State(initialValue: state.query)
        _selectedCommandID = State(initialValue: state.selectedCommandID)
    }

    public var body: some View {
        SurfacePanel(
            title: "Command palette",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissAndRestoreInvocation,
            focusTitleOnAppear: false
        ) {
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                queryField
                paletteContent
            }
        }
        .accessibilityLabel("Command palette")
        .onKeyPress(.escape) {
            dismissAndRestoreInvocation()
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            submitSelection()
        }
        .task {
            focus = .query
            ensureSelection()
        }
        .onChange(of: query) { _, newValue in
            onQueryChanged(newValue)
            ensureSelection()
        }
    }

    private var queryField: some View {
        HStack(spacing: SpaceToken.inlineStandard.points) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
            TextField("Search commands", text: $query)
                .textFieldStyle(.plain)
                .tokenFont(.uiBody, palette)
                .focused($focus, equals: .query)
                .accessibilityLabel("Command palette query")
            Text("Esc")
                .tokenFont(.uiData, palette)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel("Escape dismisses and returns to the invoking control")
        }
        .padding(.horizontal, SpaceToken.blockStandard.points)
        .padding(.vertical, SpaceToken.blockCompact.points)
        .background(palette[.surface].swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                .strokeBorder(
                    palette[.strokeDivider].swiftUIColor,
                    lineWidth: StrokeToken.paneDivider.width(palette.settings)
                )
        }
    }

    @ViewBuilder
    private var paletteContent: some View {
        switch state.presentation.state {
        case .loading:
            LoadingStateView(
                target: state.subject.target,
                step: state.subject.boundedStep ?? "Loading commands",
                cancel: dismissAndRestoreInvocation
            )
        case .error:
            ErrorStateView(
                operation: state.subject.failedOperation ?? "Load commands",
                target: state.subject.target,
                cause: state.subject.reason ?? "Command inventory failed",
                recovery: state.subject.recovery ?? "Dismiss and try again"
            )
        case .empty:
            EmptyStateView(title: "No commands", reason: state.subject.reason ?? "No commands are available")
        case .live:
            if filteredGroups.isEmpty {
                EmptyStateView(
                    title: "No matching commands",
                    reason: "No command matches ‘\(query)’"
                )
            } else {
                commandList
            }
        case .needsInput, .running, .finished, .stale, .degraded, .denied:
            noninteractiveState(state.presentation.state)
        }
    }

    private func noninteractiveState(_ presentationState: PresentationState) -> some View {
        let mark = StateMark.mark(for: presentationState)
        return HStack(alignment: .top, spacing: SpaceToken.inlineStandard.points) {
            Image(systemName: mark.symbolName)
                .tokenForeground(mark.color, palette)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                Text(mark.label)
                    .tokenFont(.uiTitle, palette)
                    .tokenForeground(.textPrimary, palette)
                Text(state.subject.reason ?? "Commands are not actionable in the current state")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
    }

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpaceToken.section.points) {
                    ForEach(filteredGroups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: SpaceToken.blockCompact.points) {
                            Text(group.title)
                                .tokenFont(.uiLabel, palette)
                                .tokenForeground(.textSecondary, palette)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.commands, id: \.id) { command in
                                commandRow(command)
                                    .id(command.id)
                            }
                        }
                    }
                }
            }
            .onChange(of: selectedCommandID) { _, identifier in
                guard let identifier else { return }
                proxy.scrollTo(identifier, anchor: .center)
            }
        }
    }

    private func commandRow(_ command: PaletteCommand) -> some View {
        let isSelected = selectedCommandID == command.id
        return Button {
            selectedCommandID = command.id
            onSubmit(command)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
                Image(systemName: isSelected ? "chevron.right" : "chevron.right.2")
                    .tokenForeground(isSelected ? .textPrimary : .textDisabled, palette)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                    Text(command.title)
                        .tokenFont(.uiBody, palette)
                        .tokenForeground(command.isEnabled ? .textPrimary : .textDisabled, palette)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .tokenFont(.uiCaption, palette)
                            .tokenForeground(.textSecondary, palette)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Text(command.shortcut)
                    .tokenFont(.uiData, palette)
                    .tokenForeground(command.isEnabled ? .textSecondary : .textDisabled, palette)
                    .lineLimit(1)
            }
            .padding(.horizontal, SpaceToken.inlineStandard.points)
            .padding(.vertical, SpaceToken.blockCompact.points)
            .background(isSelected ? palette[.selectionNative].swiftUIColor : palette[.surfaceRaised].swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .focused($focus, equals: .command(command.id))
        .modifier(KeyboardFocusRing(isFocused: focus == .command(command.id), palette: palette))
        .accessibilityLabel(command.title)
        .accessibilityValue(command.subtitle.map { "\($0), \(command.shortcut)" } ?? command.shortcut)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filteredGroups: [CommandGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return state.groups }
        return state.groups.compactMap { group in
            let commands = group.commands.filter { command in
                fuzzyMatch(trimmedQuery, in: [command.title, command.subtitle, command.shortcut]
                    .compactMap { $0 }.joined(separator: " "))
            }
            return commands.isEmpty ? nil : CommandGroup(id: group.id, title: group.title, commands: commands)
        }
    }

    private var selectableCommands: [PaletteCommand] {
        filteredGroups.flatMap(\.commands).filter(\.isEnabled)
    }

    private var permitsCommandActions: Bool {
        state.presentation.state == .live &&
            state.presentation.usability == .usableActionCapable &&
            !state.presentation.controlDisabled
    }

    private func ensureSelection() {
        guard !selectableCommands.contains(where: { $0.id == selectedCommandID }) else { return }
        selectedCommandID = selectableCommands.first?.id
    }

    private func moveSelection(by offset: Int) {
        guard permitsCommandActions else { return }
        let commands = selectableCommands
        guard !commands.isEmpty else { return }
        let current = commands.firstIndex(where: { $0.id == selectedCommandID }) ?? 0
        let next = (current + offset + commands.count) % commands.count
        selectedCommandID = commands[next].id
    }

    private func submitSelection() -> KeyPress.Result {
        guard permitsCommandActions else { return .handled }
        guard let command = selectableCommands.first(where: { $0.id == selectedCommandID }) else {
            return .handled
        }
        onSubmit(command)
        return .handled
    }

    private func fuzzyMatch(_ query: String, in candidate: String) -> Bool {
        let queryCharacters = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        let candidateCharacters = candidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        var queryIndex = queryCharacters.startIndex
        for character in candidateCharacters where queryIndex < queryCharacters.endIndex {
            if character == queryCharacters[queryIndex] {
                queryIndex = queryCharacters.index(after: queryIndex)
            }
        }
        return queryIndex == queryCharacters.endIndex
    }
}

private enum CommandPalettePreviewFixture {
    static let state = CommandPaletteViewState(
        presentation: ComposedPresentation(state: .live, usability: .usableActionCapable),
        subject: PresentationSubject(componentName: "Command palette", target: "Work Room"),
        query: "",
        groups: [
            CommandGroup(
                id: "panes",
                title: "Panes",
                commands: [
                    PaletteCommand(
                        id: "pane.split-right",
                        title: "Split pane right",
                        subtitle: "Work Room · deploy session",
                        shortcut: "⌘D",
                        isEnabled: true
                    )
                ]
            ),
            CommandGroup(
                id: "rooms",
                title: "Rooms",
                commands: [
                    PaletteCommand(
                        id: "room.switch",
                        title: "Switch to Personal",
                        subtitle: "Restore its locked input target",
                        shortcut: "⌘1",
                        isEnabled: true
                    )
                ]
            ),
            CommandGroup(
                id: "sessions",
                title: "Sessions",
                commands: [
                    PaletteCommand(
                        id: "session.local",
                        title: "New local terminal",
                        subtitle: nil,
                        shortcut: "⌘T",
                        isEnabled: true
                    )
                ]
            ),
            CommandGroup(
                id: "board",
                title: "Board",
                commands: [
                    PaletteCommand(
                        id: "board.open",
                        title: "Open board",
                        subtitle: "3 actionable items",
                        shortcut: "⌘⇧B",
                        isEnabled: true
                    )
                ]
            ),
            CommandGroup(
                id: "dictation",
                title: "Dictation",
                commands: [
                    PaletteCommand(
                        id: "dictation.start",
                        title: "Start dictation",
                        subtitle: "Locked to the selected pane",
                        shortcut: "fn",
                        isEnabled: true
                    )
                ]
            ),
            CommandGroup(
                id: "settings",
                title: "Settings",
                commands: [
                    PaletteCommand(
                        id: "settings.open",
                        title: "Open settings",
                        subtitle: nil,
                        shortcut: "⌘,",
                        isEnabled: true
                    )
                ]
            )
        ],
        selectedCommandID: "pane.split-right"
    )
}

#Preview("Command palette") {
    CommandPaletteView(
        state: CommandPalettePreviewFixture.state,
        onQueryChanged: { _ in },
        onSubmit: { _ in },
        dismissAndRestoreInvocation: {}
    )
    .allwardPalette(DesignPalette(appearance: .dark))
}
