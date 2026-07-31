import AllwardCore
import AllwardDesign
import Foundation
import SwiftUI

public enum SettingsUpdate: Hashable, Sendable {
    case selectTab(SettingsTab)
    case updateGeneral(itemID: String, value: GeneralSettingValue)
    case selectRoomTint(roomID: String, tintID: String)
    case selectRoomTheme(roomID: String, themeID: String)
    case setRoomEarcon(roomID: String, earcon: Earcon, enabled: Bool)
    case previewRoomEarcon(roomID: String, earcon: Earcon)
    case selectTheme(themeID: String)
    case importTheme(format: String)
    case setKeyShortcut(keyID: String, shortcut: String)
    case setIntegration(integrationID: String, enabled: Bool)
    case reviewPrivacy(itemID: String)
    case setRetention(itemID: String, days: Int)
}

@MainActor
public struct SettingsView: View {
    private static let speechRetentionRange = 0...365

    @Environment(\.allwardPalette) private var palette
    @FocusState private var tabPickerFocused: Bool
    @State private var selectedTab: SettingsTab
    @State private var generalValues: [String: GeneralSettingValue]
    @State private var roomTintIDs: [String: String]
    @State private var roomThemeIDs: [String: String]
    @State private var roomEarcons: [String: Bool]
    @State private var selectedThemeID: String?
    @State private var keyShortcuts: [String: String]
    @State private var integrations: [String: Bool]
    @State private var privacyValues: [String: PrivacySettingValue]

    private let state: SettingsViewState
    private let onUpdate: @MainActor (SettingsUpdate) -> Void
    private let dismissAndRestoreInvocation: @MainActor () -> Void

    public init(
        state: SettingsViewState,
        onUpdate: @escaping @MainActor (SettingsUpdate) -> Void,
        dismissAndRestoreInvocation: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onUpdate = onUpdate
        self.dismissAndRestoreInvocation = dismissAndRestoreInvocation
        _selectedTab = State(initialValue: state.selectedTab)
        _generalValues = State(initialValue: Dictionary(uniqueKeysWithValues: state.general.map { ($0.id, $0.value) }))
        _roomTintIDs = State(initialValue: Dictionary(
            uniqueKeysWithValues: state.rooms.map { ($0.id, $0.selectedTintID) }
        ))
        _roomThemeIDs = State(initialValue: Dictionary(
            uniqueKeysWithValues: state.rooms.map { ($0.id, $0.selectedThemeID) }
        ))
        _roomEarcons = State(initialValue: Dictionary(uniqueKeysWithValues: state.rooms.flatMap { room in
            room.notificationRules.map { (Self.earconKey(roomID: room.id, earcon: $0.earcon), $0.isEnabled) }
        }))
        _selectedThemeID = State(initialValue: state.themes.first(where: \.isSelected)?.id)
        _keyShortcuts = State(initialValue: Dictionary(uniqueKeysWithValues: state.keys.map { ($0.id, $0.shortcut) }))
        _integrations = State(initialValue: Dictionary(
            uniqueKeysWithValues: state.integrations.map { ($0.id, $0.isEnabled) }
        ))
        _privacyValues = State(initialValue: Dictionary(uniqueKeysWithValues: state.privacy.map { ($0.id, $0.value) }))
    }

    public var body: some View {
        SurfacePanel(
            title: "Settings",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissAndRestoreInvocation,
            focusTitleOnAppear: false
        ) {
            presentationContent
        }
        .accessibilityLabel("Settings")
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        .onKeyPress(.leftArrow) { moveSection(by: -1) }
        .onKeyPress(.rightArrow) { moveSection(by: 1) }
        .onKeyPress(.escape) {
            dismissAndRestoreInvocation()
            return .handled
        }
        .task { tabPickerFocused = true }
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch state.presentation.state {
        case .loading:
            LoadingStateView(
                target: state.subject.target,
                step: state.subject.boundedStep ?? "Loading saved settings",
                cancel: dismissAndRestoreInvocation
            )
        case .empty:
            EmptyStateView(
                title: "No settings available",
                reason: state.subject.reason ?? "No settings snapshot was published"
            )
        case .error:
            ErrorStateView(
                operation: state.subject.failedOperation ?? "Load settings",
                target: state.subject.target,
                cause: state.subject.reason ?? "The settings snapshot failed",
                recovery: state.subject.recovery ?? "Close and reopen Settings"
            )
        case .live:
            settingsContent
                .disabled(!settingsActionable)
        case .needsInput, .running, .finished, .stale, .degraded, .denied:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                settingsContent
                    .disabled(!settingsActionable)
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            tabPicker
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
            ScrollView {
                selectedSettings
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Changes are submitted immediately.")
                .tokenFont(.uiCaption, palette)
                .tokenForeground(.textSecondary, palette)
                .accessibilityLabel("Changes are submitted immediately. There is no Apply button.")
        }
    }

    private var tabPicker: some View {
        Picker("Settings section", selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tabTitle(tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .focused($tabPickerFocused)
        .modifier(KeyboardFocusRing(isFocused: tabPickerFocused, palette: palette))
        .onChange(of: selectedTab) { _, tab in emit(.selectTab(tab)) }
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selectedTab {
        case .general: generalSettings
        case .rooms: roomSettings
        case .themes: themeSettings
        case .keys: keySettings
        case .integrations: integrationSettings
        case .privacy: privacySettings
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Terminal")
            glyphSample
            ForEach(state.general) { item in
                generalControl(item)
            }
        }
    }

    private var glyphSample: some View {
        Text("00 Il1 [] {} → λ café 한글")
            .font(configuredTerminalFont)
            .tokenForeground(.textPrimary, palette)
            .textSelection(.enabled)
            .padding(SpaceToken.blockStandard.points)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: RadiusToken.control.points, style: .continuous)
                    .strokeBorder(
                        palette[.strokeDivider].swiftUIColor,
                        lineWidth: StrokeToken.paneDivider.width(palette.settings)
                    )
            }
            .accessibilityLabel(
                "Terminal font glyph sample: zero 0, capital I, lowercase l, one, " +
                    "brackets, arrow, lambda, accents, and Hangul"
            )
    }

    @ViewBuilder
    private func generalControl(_ item: GeneralSetting) -> some View {
        switch generalValue(item) {
        case .toggle(let enabled):
            Toggle(isOn: Binding(
                get: { generalToggle(item.id, fallback: enabled) },
                set: { updateGeneral(item, value: .toggle($0)) }
            )) {
                settingLabel(item.label, detail: item.detail)
            }
            .toggleStyle(.switch)
            .disabled(!item.isEnabled)
        case .choice(let selectedID, let choices):
            HStack(spacing: SpaceToken.inlineStandard.points) {
                settingLabel(item.label, detail: item.detail)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Picker(item.label, selection: Binding(
                    get: { generalChoice(item.id, fallback: selectedID) },
                    set: { updateGeneral(item, value: .choice(selectedID: $0, choices: choices)) }
                )) {
                    ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
                }
                .labelsHidden()
                .disabled(!item.isEnabled)
            }
        case .text(let text):
            HStack(spacing: SpaceToken.inlineStandard.points) {
                settingLabel(item.label, detail: item.detail)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                TextField(item.label, text: Binding(
                    get: { generalText(item.id, fallback: text) },
                    set: { updateGeneral(item, value: .text($0)) }
                ))
                .textFieldStyle(.roundedBorder)
                .tokenFont(.uiData, palette)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.label)
            }
        case .number(let value, let range, let step):
            HStack(spacing: SpaceToken.inlineStandard.points) {
                settingLabel(item.label, detail: item.detail)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Stepper(
                    value: Binding(
                        get: { generalNumber(item.id, fallback: value) },
                        set: { updateGeneral(item, value: .number(value: $0, range: range, step: step)) }
                    ),
                    in: range,
                    step: step
                ) {
                    Text(numberText(generalNumber(item.id, fallback: value)))
                        .tokenFont(.uiData, palette)
                        .tokenForeground(.textPrimary, palette)
                }
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.label)
            }
        }
    }

    private var roomSettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Rooms", count: state.rooms.count)
            if state.rooms.isEmpty {
                EmptyStateView(
                    title: "No Rooms configured",
                    reason: "Create a Room from the Room switcher before editing its settings"
                )
            } else {
                ForEach(state.rooms) { room in roomControl(room) }
            }
        }
    }

    private func roomControl(_ room: RoomSetting) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
                Text(room.name)
                    .tokenFont(.uiHeading, palette)
                    .tokenForeground(.textPrimary, palette)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Text("\(room.sessionCount) sessions · \(room.hostSummary)")
                    .tokenFont(.uiData, palette)
                    .tokenForeground(.textSecondary, palette)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("\(room.sessionCount) sessions, host \(room.hostSummary)")
            }
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text("Room tint")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Picker("Room tint", selection: roomTintBinding(room)) {
                    ForEach(room.approvedTints) { tint in
                        Label {
                            Text(tint.label)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(tint.tint.swiftUIColor)
                        }
                        .tag(tint.id)
                    }
                }
                .labelsHidden()
            }
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text("Terminal theme")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textPrimary, palette)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Picker("Terminal theme", selection: roomThemeBinding(room)) {
                    ForEach(room.themeChoices) { theme in Text(theme.label).tag(theme.id) }
                }
                .labelsHidden()
            }
            Text("Notification rules")
                .tokenFont(.uiLabel, palette)
                .tokenForeground(.textSecondary, palette)
            ForEach(room.notificationRules) { rule in earconControl(room: room, rule: rule) }
        }
        .padding(.vertical, SpaceToken.blockCompact.points)
        .overlay(alignment: .bottom) {
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
        }
        .accessibilityElement(children: .contain)
    }

    private func earconControl(room: RoomSetting, rule: EarconSetting) -> some View {
        let enabled = roomEarconValue(roomID: room.id, rule: rule)
        let mark = StateMark.mark(for: enabled ? .live : .empty)
        return HStack(spacing: SpaceToken.inlineStandard.points) {
            Toggle(isOn: roomEarconBinding(room: room, rule: rule)) {
                Label(earconLabel(rule.earcon), systemImage: mark.symbolName)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(mark.color, palette)
            }
            .toggleStyle(.switch)
            Spacer(minLength: SpaceToken.inlineStandard.points)
            Text(rule.enabledByDefault ? "On by default" : "Off by default")
                .tokenFont(.uiCaption, palette)
                .tokenForeground(.textSecondary, palette)
            Button("Preview") {
                emit(.previewRoomEarcon(roomID: room.id, earcon: rule.earcon))
            }
            .tokenFont(.uiLabel, palette)
            .accessibilityLabel("Preview \(earconLabel(rule.earcon)) for \(room.name)")
        }
    }

    private var themeSettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Themes", count: state.themes.count)
            ForEach(state.themes) { theme in
                Button {
                    selectedThemeID = theme.id
                    emit(.selectTheme(themeID: theme.id))
                } label: {
                    HStack(spacing: SpaceToken.inlineStandard.points) {
                        let selected = selectedThemeID == theme.id
                        let mark = StateMark.mark(for: selected ? .live : .empty)
                        Label(theme.name, systemImage: mark.symbolName)
                            .tokenFont(.uiBody, palette)
                            .tokenForeground(mark.color, palette)
                        Spacer(minLength: SpaceToken.inlineStandard.points)
                        Text(themeDetail(theme))
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textSecondary, palette)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedThemeID == theme.id ? "Selected" : "Not selected")
            }
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
            SectionHeader("Import")
            Text("Imports become Allward-owned themes. Source files are not live dependencies.")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            ForEach(state.themeImports) { themeImport in importControl(themeImport) }
        }
    }

    private func importControl(_ themeImport: ThemeImportSetting) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Button {
                emit(.importTheme(format: themeImport.format))
            } label: {
                Label(themeImport.label, systemImage: "square.and.arrow.down")
                    .tokenFont(.uiBody, palette)
            }
            .disabled(!themeImport.isEnabled)
            .accessibilityHint("Imports \(themeImport.format) once and reports every unmapped field")
            if let report = themeImport.report {
                let reportState: PresentationState = themeImport.unmappedFields.isEmpty ? .finished : .degraded
                let mark = StateMark.mark(for: reportState)
                Label(report, systemImage: mark.symbolName)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(mark.color, palette)
                ForEach(themeImport.unmappedFields, id: \.self) { field in
                    Text(field)
                        .tokenFont(.uiData, palette)
                        .tokenForeground(.textPrimary, palette)
                        .accessibilityLabel("Unmapped field, \(field)")
                }
            }
        }
    }

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Keyboard shortcuts", count: state.keys.count)
            ForEach(state.keys) { key in
                HStack(spacing: SpaceToken.inlineStandard.points) {
                    Text(key.action)
                        .tokenFont(.uiBody, palette)
                        .tokenForeground(.textPrimary, palette)
                    Spacer(minLength: SpaceToken.inlineStandard.points)
                    if key.isConfigurable {
                        TextField(key.action, text: keyBinding(key))
                            .textFieldStyle(.roundedBorder)
                            .tokenFont(.uiData, palette)
                            .accessibilityLabel("\(key.action) shortcut")
                    } else {
                        Text(keyShortcuts[key.id] ?? key.shortcut)
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textSecondary, palette)
                            .accessibilityLabel("\(key.action), \(key.shortcut)")
                    }
                }
            }
        }
    }

    private var integrationSettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Integrations", count: state.integrations.count)
            ForEach(state.integrations) { integration in
                VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                    HStack(spacing: SpaceToken.inlineStandard.points) {
                        Toggle(isOn: integrationBinding(integration)) {
                            Text(integration.name)
                                .tokenFont(.uiHeading, palette)
                                .tokenForeground(.textPrimary, palette)
                        }
                        .toggleStyle(.switch)
                        Spacer(minLength: SpaceToken.inlineStandard.points)
                        StateBadge(presentation: integration.presentation, subject: integration.subject)
                    }
                    if let detail = integration.detail {
                        Text(detail)
                            .tokenFont(.uiBody, palette)
                            .tokenForeground(.textSecondary, palette)
                    }
                    if let commandLine = integration.commandLine {
                        Text(commandLine)
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textPrimary, palette)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel("Client command, \(commandLine)")
                    }
                }
                .padding(.vertical, SpaceToken.blockCompact.points)
                .overlay(alignment: .bottom) {
                    Divider().overlay(palette[.strokeDivider].swiftUIColor)
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue(integration.presentation.accessibilityValue(integration.subject))
            }
        }
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            SectionHeader("Privacy")
            let telemetryMark = StateMark.mark(for: PresentationState.finished)
            Label("Zero telemetry", systemImage: telemetryMark.symbolName)
                .tokenFont(.uiHeading, palette)
                .tokenForeground(telemetryMark.color, palette)
            Text("Allward sends no product analytics or usage telemetry.")
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            ForEach(state.privacy) { item in privacyControl(item) }
        }
    }

    @ViewBuilder
    private func privacyControl(_ item: PrivacySetting) -> some View {
        let value = privacyValues[item.id] ?? item.value
        VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Text(item.label)
                .tokenFont(.uiHeading, palette)
                .tokenForeground(.textPrimary, palette)
            Text(item.detail)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            switch value {
            case .onDevice:
                privacyStatus("On device", state: .live)
            case .disabled:
                privacyStatus("Off", state: .empty)
                Button("Review opt-in") { emit(.reviewPrivacy(itemID: item.id)) }
            case .permissionRequired:
                privacyStatus("Permission required", state: .needsInput)
                Button("Review before enabling") { emit(.reviewPrivacy(itemID: item.id)) }
            case .retentionDays(let days):
                Stepper(
                    value: Binding(
                        get: { privacyRetention(item.id, fallback: days) },
                        set: { newValue in
                            privacyValues[item.id] = .retentionDays(newValue)
                            emit(.setRetention(itemID: item.id, days: newValue))
                        }
                    ),
                    in: Self.speechRetentionRange
                ) {
                    Text(days == 0 ? "Do not retain" : "Retain for \(privacyRetention(item.id, fallback: days)) days")
                        .tokenFont(.uiData, palette)
                        .tokenForeground(.textPrimary, palette)
                }
                .accessibilityLabel("\(item.label) retention")
            }
        }
        .padding(.vertical, SpaceToken.blockCompact.points)
        .overlay(alignment: .bottom) {
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
        }
    }

    private func privacyStatus(_ text: String, state: PresentationState) -> some View {
        let mark = StateMark.mark(for: state)
        return Label(text, systemImage: mark.symbolName)
            .tokenFont(.uiLabel, palette)
            .tokenForeground(mark.color, palette)
    }

    private func settingLabel(_ label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Text(label)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textPrimary, palette)
            if let detail {
                Text(detail)
                    .tokenFont(.uiCaption, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
    }

    private var configuredTerminalFont: Font {
        let terminal = palette.type(.gridBody)
        let family = generalValueText(ids: ["terminal.font-family", "font-family", "fontFamily"])
        let size = generalValueNumber(ids: ["terminal.font-size", "font-size", "fontSize"]) ?? terminal.size
        guard let family, !family.isEmpty else { return terminal.swiftUIFont }
        return Font.custom(family, size: CGFloat(size))
    }

    private var settingsActionable: Bool {
        state.presentation.usability == .usableActionCapable &&
            !state.presentation.controlDisabled
    }

    private func emit(_ update: SettingsUpdate) {
        guard settingsActionable else { return }
        onUpdate(update)
    }

    private func generalValue(_ item: GeneralSetting) -> GeneralSettingValue {
        generalValues[item.id] ?? item.value
    }

    private func updateGeneral(_ item: GeneralSetting, value: GeneralSettingValue) {
        generalValues[item.id] = value
        emit(.updateGeneral(itemID: item.id, value: value))
    }

    private func generalToggle(_ id: String, fallback: Bool) -> Bool {
        guard let stored = generalValues[id], case .toggle(let value) = stored else { return fallback }
        return value
    }

    private func generalChoice(_ id: String, fallback: String) -> String {
        guard let stored = generalValues[id], case .choice(let selectedID, _) = stored else { return fallback }
        return selectedID
    }

    private func generalText(_ id: String, fallback: String) -> String {
        guard let stored = generalValues[id], case .text(let value) = stored else { return fallback }
        return value
    }

    private func generalNumber(_ id: String, fallback: Double) -> Double {
        guard let stored = generalValues[id], case .number(let value, _, _) = stored else { return fallback }
        return value
    }

    private func generalValueText(ids: [String]) -> String? {
        for id in ids {
            guard let stored = generalValues[id] else { continue }
            if case .text(let value) = stored { return value }
            if case .choice(let selectedID, let choices) = stored {
                return choices.first(where: { $0.id == selectedID })?.label
            }
        }
        return nil
    }

    private func generalValueNumber(ids: [String]) -> Double? {
        for id in ids {
            guard let stored = generalValues[id] else { continue }
            if case .number(let value, _, _) = stored { return value }
        }
        return nil
    }

    private func roomTintBinding(_ room: RoomSetting) -> Binding<String> {
        Binding(
            get: { roomTintIDs[room.id] ?? room.selectedTintID },
            set: { tintID in
                roomTintIDs[room.id] = tintID
                emit(.selectRoomTint(roomID: room.id, tintID: tintID))
            }
        )
    }

    private func roomThemeBinding(_ room: RoomSetting) -> Binding<String> {
        Binding(
            get: { roomThemeIDs[room.id] ?? room.selectedThemeID },
            set: { themeID in
                roomThemeIDs[room.id] = themeID
                emit(.selectRoomTheme(roomID: room.id, themeID: themeID))
            }
        )
    }

    private func roomEarconBinding(room: RoomSetting, rule: EarconSetting) -> Binding<Bool> {
        let key = Self.earconKey(roomID: room.id, earcon: rule.earcon)
        return Binding(
            get: { roomEarcons[key] ?? rule.isEnabled },
            set: { enabled in
                roomEarcons[key] = enabled
                emit(.setRoomEarcon(roomID: room.id, earcon: rule.earcon, enabled: enabled))
            }
        )
    }

    private func roomEarconValue(roomID: String, rule: EarconSetting) -> Bool {
        roomEarcons[Self.earconKey(roomID: roomID, earcon: rule.earcon)] ?? rule.isEnabled
    }

    private func keyBinding(_ key: KeySetting) -> Binding<String> {
        Binding(
            get: { keyShortcuts[key.id] ?? key.shortcut },
            set: { shortcut in
                keyShortcuts[key.id] = shortcut
                emit(.setKeyShortcut(keyID: key.id, shortcut: shortcut))
            }
        )
    }

    private func integrationBinding(_ integration: IntegrationSetting) -> Binding<Bool> {
        Binding(
            get: { integrations[integration.id] ?? integration.isEnabled },
            set: { enabled in
                integrations[integration.id] = enabled
                emit(.setIntegration(integrationID: integration.id, enabled: enabled))
            }
        )
    }

    private func privacyRetention(_ id: String, fallback: Int) -> Int {
        guard let stored = privacyValues[id], case .retentionDays(let days) = stored else { return fallback }
        return days
    }

    private func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// Left and right move between sections, so Settings is reachable without
    /// a pointer even though its section control is a segmented picker.
    private func moveSection(by step: Int) -> KeyPress.Result {
        let tabs = SettingsTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return .ignored }
        let next = (index + step + tabs.count) % tabs.count
        selectedTab = tabs[next]
        return .handled
    }

    private func tabTitle(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: "General"
        case .rooms: "Rooms"
        case .themes: "Themes"
        case .keys: "Keys"
        case .integrations: "Integrations"
        case .privacy: "Privacy"
        }
    }

    private func appearanceLabel(_ appearance: Appearance) -> String {
        switch appearance {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func themeDetail(_ theme: ThemeSetting) -> String {
        let appearance = appearanceLabel(theme.appearance)
        return theme.isBuiltIn ? "Built-in · \(appearance)" : appearance
    }

    private func earconLabel(_ earcon: Earcon) -> String {
        switch earcon {
        case .needsInput: "Needs input"
        case .finished: "Finished"
        case .error: "Error"
        case .stale: "Stale"
        }
    }

    private static func earconKey(roomID: String, earcon: Earcon) -> String {
        "\(roomID)::\(earcon.rawValue)"
    }
}

#Preview("Settings") {
    SettingsView(
        state: SettingsViewState.fixture(selectedTab: .general),
        onUpdate: { _ in },
        dismissAndRestoreInvocation: {}
    )
    .frame(width: 720, height: 620)
    .padding(SpaceToken.section.points)
    .allwardPalette(DesignPalette(appearance: .dark))
}
