import AllwardCore
import AllwardMultiplexer
import AllwardRemote
import AllwardTerminal
import Foundation

public struct IdempotencyKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ControlMutationKind: String, Codable, Hashable, Sendable {
    case createLocalPane
    case createSSHPane
    case attachAdapterPane
    case closePane
    case splitPane
    case focusPane
    case movePaneFocus
    case resizePane
    case sendText
    case sendKeys
    case createTab
    case closeTab
    case setRoom
    case teleport
    case runCommand
    case createAuthoredRecord
    case updateAuthoredRecord
    case endAuthoredRecord
}

public enum ControlRejection: Error, Codable, Hashable, Sendable {
    case staleGeneration(expected: Generation, actual: Generation)
    case targetMismatch(expected: Target, actual: Target)
    case paneNotFound(PaneID)
    case tabNotFound(TabID)
    case windowNotFound(WindowID)
    case noFocusedPane(TabID)
    case unsupported(String)
    case inputDropped(String)
    case failed(AllwardError)
}

public struct ControlMutationReceipt: Codable, Hashable, Sendable {
    public var kind: ControlMutationKind
    public var target: Target
    public var generationBefore: Generation
    public var generationAfter: Generation
    public var window: WindowID?
    public var tab: TabID?
    public var pane: PaneID?

    public init(
        kind: ControlMutationKind,
        target: Target,
        generationBefore: Generation,
        generationAfter: Generation,
        window: WindowID? = nil,
        tab: TabID? = nil,
        pane: PaneID? = nil
    ) {
        self.kind = kind
        self.target = target
        self.generationBefore = generationBefore
        self.generationAfter = generationAfter
        self.window = window
        self.tab = tab
        self.pane = pane
    }
}

public enum ControlMutationResult: Codable, Hashable, Sendable {
    case applied(ControlMutationReceipt)
    case rejected(ControlRejection)
}

public struct PaneCreationRequest: Codable, Hashable, Sendable {
    public var window: WindowID
    public var tab: TabID
    public var geometry: TerminalGeometry
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        window: WindowID,
        tab: TabID,
        geometry: TerminalGeometry = .standard,
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.window = window
        self.tab = tab
        self.geometry = geometry
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct AdapterPaneRequest: Sendable {
    public var window: WindowID
    public var tab: TabID
    public var geometry: TerminalGeometry
    public var session: AdapterSession

    public init(
        window: WindowID,
        tab: TabID,
        geometry: TerminalGeometry = .standard,
        session: AdapterSession
    ) {
        self.window = window
        self.tab = tab
        self.geometry = geometry
        self.session = session
    }
}

public struct TeleportDestination: Sendable {
    public var pane: PaneID?
    public var adapterSession: AdapterSession?

    public init(pane: PaneID) {
        self.pane = pane
        self.adapterSession = nil
    }

    public init(adapterSession: AdapterSession) {
        self.pane = nil
        self.adapterSession = adapterSession
    }
}


public struct ScreenRead: Codable, Hashable, Sendable {
    public var pane: PaneID
    public var generation: Generation
    public var lines: [String]
    public var cursor: CursorState
    public var title: String?

    public init(
        pane: PaneID,
        generation: Generation,
        lines: [String],
        cursor: CursorState,
        title: String?
    ) {
        self.pane = pane
        self.generation = generation
        self.lines = lines
        self.cursor = cursor
        self.title = title
    }
}

public struct CommandOutcome: Codable, Hashable, Sendable {
    public var pane: PaneID
    public var command: String
    public var exitCode: Int32
    public var output: [String]
    public var region: CommandRegion

    public init(
        pane: PaneID,
        command: String,
        exitCode: Int32,
        output: [String],
        region: CommandRegion
    ) {
        self.pane = pane
        self.command = command
        self.exitCode = exitCode
        self.output = output
        self.region = region
    }
}

public enum RunCommandResult: Codable, Hashable, Sendable {
    case completed(CommandOutcome, ControlMutationReceipt)
    case rejected(ControlRejection)
}

public struct AuthoredMutationOutcome: Codable, Hashable, Sendable {
    public var status: String
    public var recordID: RecordID?
    public var incarnation: UUID?
    public var revision: UInt64?
    public var sourceEventID: UUID?
    public var commitOrdinal: UInt64?

    public init(
        status: String,
        recordID: RecordID?,
        incarnation: UUID?,
        revision: UInt64?,
        sourceEventID: UUID?,
        commitOrdinal: UInt64?
    ) {
        self.status = status
        self.recordID = recordID
        self.incarnation = incarnation
        self.revision = revision
        self.sourceEventID = sourceEventID
        self.commitOrdinal = commitOrdinal
    }
}

public enum AuthoredMutationResult: Codable, Hashable, Sendable {
    case completed(AuthoredMutationOutcome, ControlMutationReceipt)
    case rejected(ControlRejection)
}

public enum CommandReceiptStatus: String, Codable, Hashable, Sendable {
    case accepted
    case committed
    case final
    case error
    case cancelled
    case outcomeUnknown
}

public struct CommandExecutionReceipt: Codable, Hashable, Sendable {
    public var commandID: UUID
    public var idempotencyKey: IdempotencyKey
    public var target: Target
    public var generation: Generation
    public var status: CommandReceiptStatus
    public var exitCode: Int32?

    public init(
        commandID: UUID,
        idempotencyKey: IdempotencyKey,
        target: Target,
        generation: Generation,
        status: CommandReceiptStatus,
        exitCode: Int32? = nil
    ) {
        self.commandID = commandID
        self.idempotencyKey = idempotencyKey
        self.target = target
        self.generation = generation
        self.status = status
        self.exitCode = exitCode
    }
}
