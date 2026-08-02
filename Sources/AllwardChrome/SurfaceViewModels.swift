import AllwardCore
import AllwardDesign
import AllwardSpeech
import AllwardSurfaces
import Foundation


public struct BoardViewState: Hashable, Sendable {
    public enum ContentState: String, Hashable, Sendable, CaseIterable {
        case loading
        case noSessions
        case noOpenLoops
        case zeroPublishers
        case populated
        case staleOrDegraded
        case permission
        case error
        case maximumContent
    }


    public struct Row: Identifiable, Hashable, Sendable {
        public var id: RecordID
        public var roomName: String
        public var roomTint: TokenColor
        public var sessionTitle: String
        public var host: String
        public var workspace: String
        public var presentation: ComposedPresentation
        public var subject: PresentationSubject
        public var composition: SourceComposition
        public var openLoopCount: Int
        public var freshnessAge: TimeInterval
        public var freshnessBucket: FreshnessBucket
        public var destinationKey: String?
        public var provenanceLabel: String
        public var locallyAcknowledgeable: Bool

        public init(
            id: RecordID,
            roomName: String,
            roomTint: TokenColor,
            sessionTitle: String,
            host: String,
            workspace: String,
            presentation: ComposedPresentation,
            composition: SourceComposition,
            subject: PresentationSubject,
            openLoopCount: Int,
            freshnessAge: TimeInterval,
            freshnessBucket: FreshnessBucket,
            destinationKey: String?,
            provenanceLabel: String,
            locallyAcknowledgeable: Bool = false
        ) {
            self.id = id
            self.roomName = roomName
            self.roomTint = roomTint
            self.sessionTitle = sessionTitle
            self.host = host
            self.workspace = workspace
            self.presentation = presentation
            self.subject = subject
            self.composition = composition
            self.openLoopCount = openLoopCount
            self.freshnessAge = freshnessAge
            self.freshnessBucket = freshnessBucket
            self.destinationKey = destinationKey
            self.provenanceLabel = provenanceLabel
            self.locallyAcknowledgeable = locallyAcknowledgeable
        }
    }

    public struct HostWorkspaceGroup: Identifiable, Hashable, Sendable {
        public var id: String { "\(host)\u{1F}\(workspace)" }
        public var host: String
        public var workspace: String
        public var rows: [Row]

        public init(host: String, workspace: String, rows: [Row]) {
            self.host = host
            self.workspace = workspace
            self.rows = rows
        }
    }

    public struct RoomGroup: Identifiable, Hashable, Sendable {
        public var id: String { roomName }
        public var roomName: String
        public var roomTint: TokenColor
        public var hostWorkspaces: [HostWorkspaceGroup]

        public init(
            roomName: String,
            roomTint: TokenColor,
            hostWorkspaces: [HostWorkspaceGroup]
        ) {
            self.roomName = roomName
            self.roomTint = roomTint
            self.hostWorkspaces = hostWorkspaces
        }
    }

    public var state: ContentState
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var groups: [RoomGroup]
    public var publisherColumnsPresent: Bool
    public var inventoryStep: String?
    public var maximumVisibleRows: Int

    public init(
        state: ContentState,
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        groups: [RoomGroup],
        publisherColumnsPresent: Bool,
        inventoryStep: String? = nil,
        maximumVisibleRows: Int = 24
    ) {
        self.state = state
        self.presentation = presentation
        self.subject = subject
        self.groups = groups
        self.publisherColumnsPresent = publisherColumnsPresent
        self.inventoryStep = inventoryStep
        self.maximumVisibleRows = maximumVisibleRows
    }

    public static func fixture(
        state: ContentState = .populated,
        publisherColumnsPresent: Bool = true
    ) -> BoardViewState {
        let fixturePalette = DesignPalette(appearance: .dark)
        let commerceTint = fixturePalette[.stateRunning]
        let workshopTint = fixturePalette[.stateFinished]
        let fleetTint = fixturePalette[.stateStale]
        let permissionComposition = SourceComposition(permission: .active)
        let runningComposition = SourceComposition(work: .running)
        let liveComposition = SourceComposition.liveLocal
        let staleComposition = SourceComposition(freshness: .stale)
        let finishedComposition = SourceComposition(work: .finished, isFinishedTransitionEvent: true)
        let permission = PresentationComposer.compose(permissionComposition)
        let running = PresentationComposer.compose(runningComposition)
        let live = PresentationComposer.compose(liveComposition)
        let stale = PresentationComposer.compose(staleComposition)
        let finished = PresentationComposer.compose(finishedComposition)

        let checkout = Row(
            id: fixtureRecordID(1), roomName: "Commerce", roomTint: commerceTint,
            sessionTitle: "Checkout orchestration", host: "herdr-dev", workspace: "checkout",
            presentation: permission,
            composition: permissionComposition,
            subject: PresentationSubject(
                componentName: "Session", target: "Checkout orchestration", verb: "Allow file write",
                source: "herdr", freshnessBucket: "12s ago"),
            openLoopCount: 3, freshnessAge: 12, freshnessBucket: .seconds, destinationKey: "1",
            provenanceLabel: "herdr publisher",
            locallyAcknowledgeable: true)
        let tests = Row(
            id: fixtureRecordID(2), roomName: "Commerce", roomTint: commerceTint,
            sessionTitle: "Checkout test runner", host: "herdr-dev", workspace: "checkout",
            presentation: running,
            composition: runningComposition,
            subject: PresentationSubject(
                componentName: "Session", target: "Checkout test runner", workKind: "Agent task",
                freshnessBucket: "just now"),
            openLoopCount: 2, freshnessAge: 1, freshnessBucket: .now, destinationKey: "2",
            provenanceLabel: "herdr publisher")
        let shell = Row(
            id: fixtureRecordID(3), roomName: "Workshop", roomTint: workshopTint,
            sessionTitle: "Release notes shell", host: "local", workspace: "allward",
            presentation: live,
            composition: liveComposition,
            subject: PresentationSubject(
                componentName: "Session", target: "Release notes shell", freshnessBucket: "just now"),
            openLoopCount: 0, freshnessAge: 0, freshnessBucket: .now, destinationKey: "3",
            provenanceLabel: "Local shell")
        let command = Row(
            id: fixtureRecordID(4), roomName: "Workshop", roomTint: workshopTint,
            sessionTitle: "Package checks", host: "local", workspace: "allward",
            presentation: finished,
            composition: finishedComposition,
            subject: PresentationSubject(
                componentName: "Command", target: "swift test", resultKind: "Exit 0",
                freshnessBucket: "2m ago"),
            openLoopCount: 0, freshnessAge: 138, freshnessBucket: .minutes, destinationKey: "4",
            provenanceLabel: "OSC 133")
        let ssh = Row(
            id: fixtureRecordID(5), roomName: "Fleet", roomTint: fleetTint,
            sessionTitle: "Direct SSH observer", host: "jarvis", workspace: "/srv/allward",
            presentation: stale,
            composition: staleComposition,
            subject: PresentationSubject(
                componentName: "Session", target: "Direct SSH observer", reason: "Reconnecting",
                freshnessBucket: "18m ago"),
            openLoopCount: 0, freshnessAge: 1_080, freshnessBucket: .minutes, destinationKey: "5",
            provenanceLabel: "Direct SSH")

        let allGroups = [
            RoomGroup(
                roomName: "Commerce", roomTint: commerceTint,
                hostWorkspaces: [
                    HostWorkspaceGroup(host: "herdr-dev", workspace: "checkout", rows: [checkout, tests])
                ]),
            RoomGroup(
                roomName: "Workshop", roomTint: workshopTint,
                hostWorkspaces: [
                    HostWorkspaceGroup(host: "local", workspace: "allward", rows: [shell, command])
                ]),
            RoomGroup(
                roomName: "Fleet", roomTint: fleetTint,
                hostWorkspaces: [
                    HostWorkspaceGroup(host: "jarvis", workspace: "/srv/allward", rows: [ssh])
                ]),
        ]
        let groups: [RoomGroup] = switch state {
        case .noSessions:
            []
        case .noOpenLoops:
            allGroups.map { room in
                var room = room
                room.hostWorkspaces = room.hostWorkspaces.map { hostWorkspace in
                    var hostWorkspace = hostWorkspace
                    hostWorkspace.rows = hostWorkspace.rows.map { row in
                        var row = row
                        row.openLoopCount = 0
                        return row
                    }
                    return hostWorkspace
                }
                return room
            }
        case .zeroPublishers:
            allGroups.map { room in
                var room = room
                room.hostWorkspaces = room.hostWorkspaces.map { hostWorkspace in
                    var hostWorkspace = hostWorkspace
                    hostWorkspace.rows = hostWorkspace.rows.map { row in
                        var row = row
                        row.openLoopCount = 0
                        row.locallyAcknowledgeable = false
                        return row
                    }
                    return hostWorkspace
                }
                return room
            }
        default:
            allGroups
        }
        let presentationState: PresentationState = switch state {
        case .loading: .loading
        case .noSessions, .noOpenLoops: .empty
        case .staleOrDegraded: .degraded
        case .permission: .needsInput
        case .error: .error
        case .zeroPublishers, .populated, .maximumContent: .live
        }
        let presentation = ComposedPresentation(
            state: presentationState,
            usability: presentationState == .loading ? .closedAbsent : .usableActionCapable)
        let subjectTarget = switch state {
        case .loading: "Commerce / herdr-dev connection"
        case .noSessions: "Commerce"
        case .staleOrDegraded: "Commerce / herdr workspace"
        case .permission: "Commerce / Checkout orchestration"
        case .error: "Fleet / jarvis SSH"
        default: "Session inventory"
        }
        return BoardViewState(
            state: state, presentation: presentation,
            subject: PresentationSubject(
                componentName: "Board", target: subjectTarget,
                reason: state == .noSessions ? "No sessions yet" : nil,
                capability: state == .staleOrDegraded ? "herdr workspace inventory" : nil,
                verb: state == .permission ? "Review permission" : nil,
                source: state == .permission ? "herdr" : nil,
                failedOperation: state == .error ? "Refresh direct SSH source" : nil,
                recovery: state == .error ? "Retry source or open diagnostics" : nil,
                boundedStep: state == .loading ? "Inventory attempt 1 of 3" : nil),
            groups: groups,
            publisherColumnsPresent: publisherColumnsPresent && state != .zeroPublishers,
            inventoryStep: state == .loading ? "Inventory attempt 1 of 3" : nil)
    }

    private static func fixtureRecordID(_ suffix: Int) -> RecordID {
        let text = String(format: "00000000-0000-0000-0000-%012d", suffix)
        return RecordID(rawValue: UUID(uuidString: text)!)
    }
}

public struct RouterViewState: Hashable, Sendable {
    public enum ZeroState: String, Hashable, Sendable, CaseIterable {
        case none
        case noActionableItems
        case zeroPublishers
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public var id: RecordID
        public var attentionClass: AttentionClass
        public var presentation: ComposedPresentation
        public var subject: PresentationSubject
        public var composition: SourceComposition
        public var roomName: String
        public var destinationKey: String?
        public var provenanceLabel: String

        public init(
            id: RecordID,
            attentionClass: AttentionClass,
            presentation: ComposedPresentation,
            composition: SourceComposition,
            subject: PresentationSubject,
            roomName: String,
            destinationKey: String?,
            provenanceLabel: String
        ) {
            self.id = id
            self.attentionClass = attentionClass
            self.presentation = presentation
            self.subject = subject
            self.composition = composition
            self.roomName = roomName
            self.destinationKey = destinationKey
            self.provenanceLabel = provenanceLabel
        }
    }

    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var highestClass: AttentionClass?
    public var actionableCount: Int
    public var roomName: String
    public var roomTint: TokenColor
    public var freshnessAge: TimeInterval
    public var destinationKey: String?
    public var items: [Item]
    public var newEpochs: [RecordID]
    public var focusFiltered: Bool
    public var zeroState: ZeroState

    public init(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        highestClass: AttentionClass?,
        actionableCount: Int,
        roomName: String,
        roomTint: TokenColor,
        freshnessAge: TimeInterval,
        destinationKey: String?,
        items: [Item],
        newEpochs: [RecordID],
        focusFiltered: Bool,
        zeroState: ZeroState
    ) {
        self.presentation = presentation
        self.subject = subject
        self.highestClass = highestClass
        self.actionableCount = actionableCount
        self.roomName = roomName
        self.roomTint = roomTint
        self.freshnessAge = freshnessAge
        self.destinationKey = destinationKey
        self.items = items
        self.newEpochs = newEpochs
        self.focusFiltered = focusFiltered
        self.zeroState = zeroState
    }

    public static func fixture(
        zeroState: ZeroState = .none,
        focusFiltered: Bool = false
    ) -> RouterViewState {
        let hasActions = zeroState == .none
        let roomTint = DesignPalette(appearance: .dark)[.stateRunning]
        let composition = SourceComposition(
            freshness: hasActions ? .live : .superseded,
            permission: hasActions ? .active : .none,
            focus: focusFiltered ? .denied : .allowed)
        let presentation = PresentationComposer.compose(composition)
        let subject = PresentationSubject(
            componentName: "Router", target: "Commerce attention",
            reason: hasActions ? nil : "No actionable items",
            verb: hasActions ? "Review permission" : nil, source: hasActions ? "herdr" : nil,
            freshnessBucket: "12s ago")
        let item = Item(
            id: RecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
            attentionClass: .needsInput, presentation: presentation, composition: composition,
            subject: subject,
            roomName: "Commerce", destinationKey: "1", provenanceLabel: "herdr publisher")
        return RouterViewState(
            presentation: presentation, subject: subject,
            highestClass: hasActions ? .needsInput : nil, actionableCount: hasActions ? 1 : 0,
            roomName: "Commerce", roomTint: roomTint, freshnessAge: 12,
            destinationKey: hasActions ? "1" : nil, items: hasActions ? [item] : [],
            newEpochs: hasActions ? [item.id] : [], focusFiltered: focusFiltered,
            zeroState: zeroState)
    }
}

public struct DigestViewState: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case preparing(step: String)
        case readyDeterministic
        case readyRewritten(prose: String)
        case focusFiltered
        case absent
        case sourceStale(reason: String)
        case partialSourceError(source: String, cause: String)
        case acknowledged
    }

    public struct Fact: Identifiable, Hashable, Sendable {
        public var id: SurfaceEventID
        public var text: String
        public var target: String
        public var roomName: String
        public var sessionTitle: String
        public var sourceLabel: String
        public var sourceRecordID: RecordID
        public var sourceCommandID: String?
        public var freshnessAge: TimeInterval
        public var presentation: ComposedPresentation
        public var subject: PresentationSubject
        public var composition: SourceComposition

        public init(
            id: SurfaceEventID,
            text: String,
            target: String,
            roomName: String,
            sessionTitle: String,
            sourceLabel: String,
            sourceRecordID: RecordID,
            sourceCommandID: String?,
            freshnessAge: TimeInterval,
            presentation: ComposedPresentation,
            composition: SourceComposition,
            subject: PresentationSubject
        ) {
            self.id = id
            self.text = text
            self.target = target
            self.roomName = roomName
            self.sessionTitle = sessionTitle
            self.sourceLabel = sourceLabel
            self.sourceRecordID = sourceRecordID
            self.sourceCommandID = sourceCommandID
            self.freshnessAge = freshnessAge
            self.presentation = presentation
            self.composition = composition
            self.subject = subject
        }
    }

    public var allowedUnseenEventCount: Int
    public var orderedFacts: [Fact]
    public var state: State
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject

    public init(
        allowedUnseenEventCount: Int,
        orderedFacts: [Fact],
        state: State,
        presentation: ComposedPresentation,
        subject: PresentationSubject
    ) {
        self.allowedUnseenEventCount = allowedUnseenEventCount
        self.orderedFacts = orderedFacts
        self.state = state
        self.presentation = presentation
        self.subject = subject
    }

    public static func fixture(state: State = .readyDeterministic) -> DigestViewState {
        let finishedComposition = SourceComposition(work: .finished, isFinishedTransitionEvent: true)
        let needsInputComposition = SourceComposition(permission: .active)
        let finished = PresentationComposer.compose(finishedComposition)
        let needsInput = PresentationComposer.compose(needsInputComposition)
        let facts = [
            Fact(
                id: SurfaceEventID(
                    recordID: RecordID(
                        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!),
                    ordinal: 1),
                text: "Package checks finished with exit 0.", target: "Workshop / Package checks",
                roomName: "Workshop", sessionTitle: "Package checks", sourceLabel: "OSC 133 command",
                sourceRecordID: RecordID(
                    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!),
                sourceCommandID: "4",
                freshnessAge: 138, presentation: finished,
                composition: finishedComposition,
                subject: PresentationSubject(
                    componentName: "Digest fact", target: "Package checks", resultKind: "Exit 0")),
            Fact(
                id: SurfaceEventID(
                    recordID: RecordID(
                        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!),
                    ordinal: 2),
                text: "Checkout orchestration needs a file-write decision.",
                target: "Commerce / Checkout orchestration", roomName: "Commerce",
                sessionTitle: "Checkout orchestration", sourceLabel: "herdr permission",
                sourceRecordID: RecordID(
                    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!),
                sourceCommandID: "1",
                freshnessAge: 12, presentation: needsInput,
                composition: needsInputComposition,
                subject: PresentationSubject(
                    componentName: "Digest fact", target: "Checkout orchestration",
                    verb: "Allow file write", source: "herdr")),
        ]
        let presentationState: PresentationState = switch state {
        case .preparing: .loading
        case .absent, .acknowledged: .empty
        case .sourceStale: .stale
        case .partialSourceError: .error
        case .readyDeterministic, .readyRewritten, .focusFiltered: .live
        }
        let focusFiltered = if case .focusFiltered = state { true } else { false }
        let reason: String? = switch state {
        case .absent: "No meaningful unseen changes"
        case .acknowledged: "Acknowledged"
        case .sourceStale(let reason): reason
        default: nil
        }
        let failedOperation: String? = if case .partialSourceError(let source, _) = state {
            "Read \(source)"
        } else { nil }
        let recovery: String? = if case .partialSourceError(_, let cause) = state { cause } else { nil }
        let boundedStep: String? = if case .preparing(let step) = state { step } else { nil }
        let presentation = ComposedPresentation(
            state: presentationState,
            usability: presentationState == .loading ? .closedAbsent : .usableActionCapable,
            focusFiltered: focusFiltered)
        return DigestViewState(
            allowedUnseenEventCount: state == .absent ? 0 : 2,
            orderedFacts: state == .absent ? [] : facts, state: state, presentation: presentation,
            subject: PresentationSubject(
                componentName: "Digest", target: "Re-entry digest", reason: reason,
                failedOperation: failedOperation, recovery: recovery, boundedStep: boundedStep,
                freshnessBucket: "18m ago"))
    }
}


public struct PaletteCommand: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var shortcut: String
    public var isEnabled: Bool

    public init(id: String, title: String, subtitle: String?, shortcut: String, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}

public struct CommandGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var commands: [PaletteCommand]

    public init(id: String, title: String, commands: [PaletteCommand]) {
        self.id = id
        self.title = title
        self.commands = commands
    }
}

public struct CommandPaletteViewState: Hashable, Sendable {
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var query: String
    public var groups: [CommandGroup]
    public var selectedCommandID: String?

    public init(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        query: String,
        groups: [CommandGroup],
        selectedCommandID: String?
    ) {
        self.presentation = presentation
        self.subject = subject
        self.query = query
        self.groups = groups
        self.selectedCommandID = selectedCommandID
    }

    public static func fixture() -> CommandPaletteViewState {
        CommandPaletteViewState(
            presentation: ComposedPresentation(state: .live, usability: .usableActionCapable),
            subject: PresentationSubject(componentName: "Command palette", target: "Commands"),
            query: "", groups: [
                CommandGroup(id: "navigation", title: "Navigation", commands: [
                    PaletteCommand(
                        id: "board", title: "Open Board", subtitle: "All sessions and attention",
                        shortcut: Shortcut.board.display, isEnabled: true),
                    PaletteCommand(
                        id: "digest", title: "Open digest", subtitle: "Changes since your last visit",
                        shortcut: Shortcut.digest.display, isEnabled: true),
                ]),
            ], selectedCommandID: "board")
    }
}

public struct DictationViewState: Hashable, Sendable {
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var phase: SpeechState
    public var lockedTarget: String
    public var transcript: String?
    public var destinationIsValid: Bool
    public var assetActionTitle: String?

    public init(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        phase: SpeechState,
        lockedTarget: String,
        transcript: String?,
        destinationIsValid: Bool,
        assetActionTitle: String?
    ) {
        self.presentation = presentation
        self.subject = subject
        self.phase = phase
        self.lockedTarget = lockedTarget
        self.transcript = transcript
        self.destinationIsValid = destinationIsValid
        self.assetActionTitle = assetActionTitle
    }

    public static func fixture(phase: SpeechState = .transcriptRetained) -> DictationViewState {
        DictationViewState(
            presentation: ComposedPresentation(state: .live, usability: .usableActionCapable),
            subject: PresentationSubject(componentName: "Dictation", target: "Release notes shell"),
            phase: phase, lockedTarget: "Workshop / Release notes shell",
            transcript: "Run the focused package checks, then summarize failures.",
            destinationIsValid: true, assetActionTitle: nil)
    }
}


public enum SettingsTab: String, Identifiable, Hashable, Sendable, CaseIterable {
    case general
    case rooms
    case themes
    case keys
    case integrations

    public var id: String { rawValue }
}

public struct SettingChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public enum GeneralSettingValue: Hashable, Sendable {
    case toggle(Bool)
    case choice(selectedID: String, choices: [SettingChoice])
    case text(String)
    case number(value: Double, range: ClosedRange<Double>, step: Double)
}

public struct GeneralSetting: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?
    public var value: GeneralSettingValue
    public var isEnabled: Bool
    public init(id: String, label: String, detail: String?, value: GeneralSettingValue, isEnabled: Bool) {
        self.id = id; self.label = label; self.detail = detail; self.value = value; self.isEnabled = isEnabled
    }
}

public struct RoomTintChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var tint: TokenColor
    public init(id: String, label: String, tint: TokenColor) {
        self.id = id; self.label = label; self.tint = tint
    }
}

public struct EarconSetting: Identifiable, Hashable, Sendable {
    public var id: Earcon { earcon }
    public var earcon: Earcon
    public var isEnabled: Bool
    public var enabledByDefault: Bool
    public init(earcon: Earcon, isEnabled: Bool, enabledByDefault: Bool) {
        self.earcon = earcon; self.isEnabled = isEnabled; self.enabledByDefault = enabledByDefault
    }
}

public struct RoomSetting: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var hostSummary: String
    public var sessionCount: Int
    public var selectedTintID: String
    public var approvedTints: [RoomTintChoice]
    public var selectedThemeID: String
    public var themeChoices: [SettingChoice]
    public var notificationRules: [EarconSetting]
    public init(
        id: String, name: String, hostSummary: String, sessionCount: Int,
        selectedTintID: String, approvedTints: [RoomTintChoice],
        selectedThemeID: String, themeChoices: [SettingChoice],
        notificationRules: [EarconSetting]
    ) {
        self.id = id; self.name = name; self.hostSummary = hostSummary; self.sessionCount = sessionCount
        self.selectedTintID = selectedTintID; self.approvedTints = approvedTints
        self.selectedThemeID = selectedThemeID; self.themeChoices = themeChoices
        self.notificationRules = notificationRules
    }
}

public struct ThemeSetting: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var appearance: Appearance
    public var isBuiltIn: Bool
    public var isSelected: Bool
    public init(id: String, name: String, appearance: Appearance, isBuiltIn: Bool, isSelected: Bool) {
        self.id = id; self.name = name; self.appearance = appearance
        self.isBuiltIn = isBuiltIn; self.isSelected = isSelected
    }
}

public struct KeySetting: Identifiable, Hashable, Sendable {
    public var id: String
    public var action: String
    public var shortcut: String
    public var isConfigurable: Bool
    public init(id: String, action: String, shortcut: String, isConfigurable: Bool) {
        self.id = id; self.action = action; self.shortcut = shortcut; self.isConfigurable = isConfigurable
    }
}

public struct IntegrationSetting: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?
    public var commandLine: String?
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var isEnabled: Bool
    /// Whether this integration is something you switch, or something that
    /// reports. herdr appears when a herdr server is running and goes away when
    /// it stops, so a switch beside it is a lie.
    public var isSwitchable: Bool
    public init(
        id: String, name: String, detail: String?, commandLine: String?,
        presentation: ComposedPresentation, subject: PresentationSubject, isEnabled: Bool,
        isSwitchable: Bool = true
    ) {
        self.isSwitchable = isSwitchable
        self.id = id; self.name = name; self.detail = detail; self.commandLine = commandLine
        self.presentation = presentation; self.subject = subject; self.isEnabled = isEnabled
    }
}

public enum PrivacySettingValue: Hashable, Sendable {
    case onDevice
    case disabled
    case permissionRequired
}


public struct SettingsViewState: Hashable, Sendable {
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var selectedTab: SettingsTab
    public var general: [GeneralSetting]
    public var appearance: [GeneralSetting]
    public var sound: [GeneralSetting]
    public var rooms: [RoomSetting]
    public var themes: [ThemeSetting]
    public var keys: [KeySetting]
    public var integrations: [IntegrationSetting]
    public init(
        presentation: ComposedPresentation, subject: PresentationSubject, selectedTab: SettingsTab,
        general: [GeneralSetting], appearance: [GeneralSetting] = [], sound: [GeneralSetting] = [],
        rooms: [RoomSetting], themes: [ThemeSetting],
        keys: [KeySetting],
        integrations: [IntegrationSetting]
    ) {
        self.presentation = presentation; self.subject = subject; self.selectedTab = selectedTab
        self.general = general; self.appearance = appearance; self.sound = sound
        self.rooms = rooms; self.themes = themes
        self.keys = keys
        self.integrations = integrations
    }

    public static func fixture(selectedTab: SettingsTab = .general) -> SettingsViewState {
        let palette = DesignPalette(appearance: .dark)
        let tints = [
            RoomTintChoice(id: "blue", label: "Blue", tint: palette[.stateRunning]),
            RoomTintChoice(id: "green", label: "Green", tint: palette[.stateFinished]),
            RoomTintChoice(id: "slate", label: "Slate", tint: palette[.stateStale]),
        ]
        let themes = [
            SettingChoice(id: "allward-dark", label: "Allward dark"),
            SettingChoice(id: "allward-light", label: "Allward light"),
        ]
        let rules = Earcon.allCases.map {
            EarconSetting(earcon: $0, isEnabled: false, enabledByDefault: false)
        }
        let live = ComposedPresentation(state: .live, usability: .usableActionCapable)
        func room(_ id: String, _ name: String, _ host: String, _ count: Int, _ tint: String) -> RoomSetting {
            RoomSetting(
                id: id, name: name, hostSummary: host, sessionCount: count,
                selectedTintID: tint, approvedTints: tints,
                selectedThemeID: "allward-dark", themeChoices: themes, notificationRules: rules)
        }
        return SettingsViewState(
            presentation: live,
            subject: PresentationSubject(componentName: "Settings", target: "Allward settings"),
            selectedTab: selectedTab,
            general: [
                GeneralSetting(
                    id: "restore", label: "Restore windows", detail: nil,
                    value: .toggle(true), isEnabled: true),
                GeneralSetting(
                    id: "terminal.font-family", label: "Terminal font family", detail: nil,
                    value: .text("JetBrains Mono"), isEnabled: true),
                GeneralSetting(
                    id: "font-size", label: "Terminal font size", detail: nil,
                    value: .number(value: 13, range: 9...32, step: 1), isEnabled: true),
                GeneralSetting(
                    id: "cursor-shape", label: "Cursor shape", detail: nil,
                    value: .choice(
                        selectedID: "block",
                        choices: [
                            SettingChoice(id: "block", label: "Block"),
                            SettingChoice(id: "beam", label: "Beam"),
                            SettingChoice(id: "underline", label: "Underline"),
                        ]),
                    isEnabled: true),
                GeneralSetting(
                    id: "cursor-blink", label: "Cursor blink", detail: nil,
                    value: .toggle(false), isEnabled: true),
                GeneralSetting(
                    id: "scrollback", label: "Scrollback lines", detail: nil,
                    value: .number(value: 10_000, range: 1_000...100_000, step: 1_000),
                    isEnabled: true),
            ],
            rooms: [
                room("commerce", "Commerce", "herdr-dev", 2, "blue"),
                room("workshop", "Workshop", "local", 2, "green"),
                room("fleet", "Fleet", "jarvis", 1, "slate"),
            ],
            themes: [
                ThemeSetting(
                    id: "allward-dark", name: "Allward dark", appearance: .dark,
                    isBuiltIn: true, isSelected: true),
                ThemeSetting(
                    id: "allward-light", name: "Allward light", appearance: .light,
                    isBuiltIn: true, isSelected: false),
            ],
            keys: Self.fixtureKeys,
            integrations: [
                IntegrationSetting(
                    id: "herdr", name: "herdr", detail: "Workspace adapter available",
                    commandLine: nil, presentation: live,
                    subject: PresentationSubject(componentName: "Integration", target: "herdr"),
                    isEnabled: true),
                IntegrationSetting(
                    id: "mcp", name: "MCP", detail: "Local client command",
                    commandLine: "allward-mcp", presentation: live,
                    subject: PresentationSubject(componentName: "Integration", target: "Allward MCP"),
                    isEnabled: true),
            ])
    }

    private static let fixtureKeys = [
        KeySetting(id: "new-local", action: "New local terminal", shortcut: Shortcut.newTab.display, isConfigurable: false),
        KeySetting(id: "new-window", action: "New window", shortcut: Shortcut.newWindow.display, isConfigurable: false),
        KeySetting(id: "close-pane", action: "Close pane", shortcut: Shortcut.closePane.display, isConfigurable: false),
        KeySetting(id: "split-right", action: "Split right", shortcut: Shortcut.splitRight.display, isConfigurable: false),
        KeySetting(id: "split-down", action: "Split down", shortcut: Shortcut.splitDown.display, isConfigurable: false),
        KeySetting(id: "focus-pane", action: "Focus pane", shortcut: Shortcut.focusPane, isConfigurable: false),
        KeySetting(id: "tabs", action: "Next or previous tab", shortcut: Shortcut.tabCycle, isConfigurable: false),
        KeySetting(id: "ssh", action: "Connect to SSH host", shortcut: Shortcut.connectSSH.display, isConfigurable: false),
        KeySetting(id: "board", action: "Open Board", shortcut: Shortcut.board.display, isConfigurable: false),
        KeySetting(id: "digest", action: "Open digest", shortcut: Shortcut.digest.display, isConfigurable: false),
        KeySetting(id: "palette", action: "Command palette", shortcut: Shortcut.palette.display, isConfigurable: false),
        KeySetting(id: "rooms", action: "Room switcher", shortcut: Shortcut.rooms.display, isConfigurable: false),
        KeySetting(id: "teleport", action: "Teleport", shortcut: Shortcut.teleport.display, isConfigurable: false),
        KeySetting(id: "settings", action: "Settings", shortcut: Shortcut.settings.display, isConfigurable: false),
        KeySetting(id: "diagnostics", action: "Diagnostics", shortcut: KeyChord("/", [.command, .shift]).display, isConfigurable: false),
        KeySetting(id: "speech.dictation-key", action: "Hold to dictate", shortcut: "fn", isConfigurable: true),
    ]
}

public struct ProtocolCounters: Hashable, Sendable {
    public var accepted: UInt64
    public var ignored: UInt64
    public var rejected: UInt64
    public var superseded: UInt64

    public init(accepted: UInt64, ignored: UInt64, rejected: UInt64, superseded: UInt64) {
        self.accepted = accepted
        self.ignored = ignored
        self.rejected = rejected
        self.superseded = superseded
    }
}

public struct ReasonCount: Identifiable, Hashable, Sendable {
    public var id: String
    public var reason: String
    public var count: UInt64

    public init(id: String, reason: String, count: UInt64) {
        self.id = id
        self.reason = reason
        self.count = count
    }
}

public struct LeaseDiagnostic: Hashable, Sendable {
    public var publisher: String
    public var generation: Generation
    public var expiresIn: TimeInterval?
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public init(
        publisher: String, generation: Generation, expiresIn: TimeInterval?,
        presentation: ComposedPresentation, subject: PresentationSubject
    ) {
        self.publisher = publisher; self.generation = generation; self.expiresIn = expiresIn
        self.presentation = presentation; self.subject = subject
    }
}

public struct AdapterDiagnostic: Hashable, Sendable {
    public var name: String
    public var route: String
    public var reason: String?
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public init(
        name: String, route: String, reason: String?,
        presentation: ComposedPresentation, subject: PresentationSubject
    ) {
        self.name = name; self.route = route; self.reason = reason
        self.presentation = presentation; self.subject = subject
    }
}

public enum ConnectionCause: Hashable, Sendable {
    case resolvingFailure(String)
    case authenticationDenied(String)
    case retryable(String)
    case nonretryable(String)
    case userCancelled
}

public struct ConnectionDiagnostic: Hashable, Sendable {
    public var target: String
    public var attempt: Int
    public var maximumAttempts: Int
    public var lastCause: ConnectionCause?
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public init(
        target: String, attempt: Int, maximumAttempts: Int, lastCause: ConnectionCause?,
        presentation: ComposedPresentation, subject: PresentationSubject
    ) {
        self.target = target; self.attempt = attempt; self.maximumAttempts = maximumAttempts
        self.lastCause = lastCause; self.presentation = presentation; self.subject = subject
    }
}

public struct RendererDiagnostic: Hashable, Sendable {
    public var framesSubmitted: UInt64
    public var atlasGeneration: Generation
    public var atlasOccupancyPercent: Double
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public init(
        framesSubmitted: UInt64, atlasGeneration: Generation, atlasOccupancyPercent: Double,
        presentation: ComposedPresentation, subject: PresentationSubject
    ) {
        self.framesSubmitted = framesSubmitted; self.atlasGeneration = atlasGeneration
        self.atlasOccupancyPercent = atlasOccupancyPercent
        self.presentation = presentation; self.subject = subject
    }
}

public struct MCPGrantDiagnostic: Identifiable, Hashable, Sendable {
    public var id: String
    public var clientName: String
    public var scope: String
    public var expiresIn: TimeInterval?
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public init(
        id: String, clientName: String, scope: String, expiresIn: TimeInterval?,
        presentation: ComposedPresentation, subject: PresentationSubject
    ) {
        self.id = id; self.clientName = clientName; self.scope = scope; self.expiresIn = expiresIn
        self.presentation = presentation; self.subject = subject
    }
}

public enum DiagnosticsExportField: Identifiable, Hashable, Sendable {
    case rendererBackendMetal
    case protocolAccepted(UInt64)
    case protocolIgnored(UInt64)
    case protocolRejected(UInt64)
    case protocolSuperseded(UInt64)
    case rendererFrames(UInt64)
    case atlasGeneration(Generation)
    case atlasOccupancyPercent(Double)

    public var id: String {
        switch self {
        case .rendererBackendMetal: "renderer.backend"
        case .protocolAccepted: "protocol.accepted"
        case .protocolIgnored: "protocol.ignored"
        case .protocolRejected: "protocol.rejected"
        case .protocolSuperseded: "protocol.superseded"
        case .rendererFrames: "renderer.frames"
        case .atlasGeneration: "renderer.atlas-generation"
        case .atlasOccupancyPercent: "renderer.atlas-occupancy"
        }
    }

    public var label: String {
        switch self {
        case .rendererBackendMetal: "Renderer"
        case .protocolAccepted: "Protocol accepted"
        case .protocolIgnored: "Protocol ignored"
        case .protocolRejected: "Protocol rejected"
        case .protocolSuperseded: "Protocol superseded"
        case .rendererFrames: "Renderer frames"
        case .atlasGeneration: "Atlas generation"
        case .atlasOccupancyPercent: "Atlas occupancy"
        }
    }

    public var safeValue: String {
        switch self {
        case .rendererBackendMetal: "Metal"
        case .protocolAccepted(let value),
             .protocolIgnored(let value),
             .protocolRejected(let value),
             .protocolSuperseded(let value),
             .rendererFrames(let value):
            "\(value)"
        case .atlasGeneration(let value):
            "\(value.rawValue)"
        case .atlasOccupancyPercent(let value):
            "\(value)%"
        }
    }
}

public struct DiagnosticsViewState: Hashable, Sendable {
    public var presentation: ComposedPresentation
    public var subject: PresentationSubject
    public var protocolCounters: ProtocolCounters
    public var ignoredReasons: [ReasonCount]
    public var rejectedReasons: [ReasonCount]
    public var lease: LeaseDiagnostic
    public var adapter: AdapterDiagnostic
    public var connection: ConnectionDiagnostic
    public var renderer: RendererDiagnostic
    public var mcpGrants: [MCPGrantDiagnostic]
    public var safeExportFields: [DiagnosticsExportField]
    public var exportFileName: String
    public var exportEnabled: Bool

    public init(
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        protocolCounters: ProtocolCounters,
        ignoredReasons: [ReasonCount],
        rejectedReasons: [ReasonCount],
        lease: LeaseDiagnostic,
        adapter: AdapterDiagnostic,
        connection: ConnectionDiagnostic,
        renderer: RendererDiagnostic,
        mcpGrants: [MCPGrantDiagnostic],
        safeExportFields: [DiagnosticsExportField],
        exportFileName: String,
        exportEnabled: Bool
    ) {
        self.presentation = presentation; self.subject = subject
        self.protocolCounters = protocolCounters; self.ignoredReasons = ignoredReasons
        self.rejectedReasons = rejectedReasons; self.lease = lease; self.adapter = adapter
        self.connection = connection; self.renderer = renderer; self.mcpGrants = mcpGrants
        self.safeExportFields = safeExportFields; self.exportFileName = exportFileName
        self.exportEnabled = exportEnabled
    }

    public static func fixture() -> DiagnosticsViewState {
        let live = ComposedPresentation(state: .live, usability: .usableActionCapable)
        return DiagnosticsViewState(
            presentation: live,
            subject: PresentationSubject(componentName: "Diagnostics", target: "Allward diagnostics"),
            protocolCounters: ProtocolCounters(accepted: 284, ignored: 7, rejected: 2, superseded: 11),
            ignoredReasons: [ReasonCount(id: "duplicate", reason: "Duplicate sequence", count: 7)],
            rejectedReasons: [ReasonCount(id: "signature", reason: "Invalid signature", count: 2)],
            lease: LeaseDiagnostic(
                publisher: "herdr", generation: Generation(rawValue: 42), expiresIn: 48,
                presentation: live,
                subject: PresentationSubject(componentName: "Diagnostics", target: "Publisher lease")),
            adapter: AdapterDiagnostic(
                name: "herdr", route: "workspace checkout", reason: nil, presentation: live,
                subject: PresentationSubject(componentName: "Diagnostics", target: "herdr adapter")),
            connection: ConnectionDiagnostic(
                target: "jarvis SSH", attempt: 1, maximumAttempts: 3, lastCause: nil,
                presentation: live,
                subject: PresentationSubject(componentName: "Diagnostics", target: "jarvis SSH")),
            renderer: RendererDiagnostic(
                framesSubmitted: 18_204, atlasGeneration: Generation(rawValue: 9),
                atlasOccupancyPercent: 62.5, presentation: live,
                subject: PresentationSubject(componentName: "Diagnostics", target: "Terminal renderer")),
            mcpGrants: [
                MCPGrantDiagnostic(
                    id: "mcp-local", clientName: "Local Allward MCP", scope: "Board and diagnostics",
                    expiresIn: nil, presentation: live,
                    subject: PresentationSubject(componentName: "Diagnostics", target: "Local Allward MCP")),
            ],
            safeExportFields: [
                .rendererBackendMetal,
                .protocolAccepted(284),
            ],
            exportFileName: "allward-diagnostics.txt",
            exportEnabled: true)
    }
}
