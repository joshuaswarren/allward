import AllwardCore
import Foundation

// The immutable hand-off from the terminal engine to every consumer: renderer,
// accessibility projection, selection, search, and control. Consumers never
// reach into mutable engine state (SPEC §3 "Grid and scrollback contract").

/// Terminal geometry in cells. One geometry belongs to one coherent generation;
/// a snapshot never mixes two.
public struct TerminalGeometry: Hashable, Sendable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public static let standard = TerminalGeometry(columns: 80, rows: 24)
}

/// A terminal colour. Indexed values resolve through the active theme so a
/// palette change repaints without touching cell storage.
public enum TerminalColor: Hashable, Sendable, Codable {
    case defaultForeground
    case defaultBackground
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// Interned cell styling. Repeated attributes never allocate per cell.
public struct CellAttributes: Hashable, Sendable, Codable {
    public struct Flags: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let bold = Flags(rawValue: 1 << 0)
        public static let faint = Flags(rawValue: 1 << 1)
        public static let italic = Flags(rawValue: 1 << 2)
        public static let underline = Flags(rawValue: 1 << 3)
        public static let doubleUnderline = Flags(rawValue: 1 << 4)
        public static let curlyUnderline = Flags(rawValue: 1 << 5)
        public static let blink = Flags(rawValue: 1 << 6)
        public static let inverse = Flags(rawValue: 1 << 7)
        public static let invisible = Flags(rawValue: 1 << 8)
        public static let strikethrough = Flags(rawValue: 1 << 9)
        public static let protected = Flags(rawValue: 1 << 10)
    }

    public var foreground: TerminalColor
    public var background: TerminalColor
    public var underlineColor: TerminalColor?
    public var flags: Flags
    /// OSC 8 hyperlink id, interned in the session's link table.
    public var hyperlinkID: UInt32?

    public init(
        foreground: TerminalColor = .defaultForeground,
        background: TerminalColor = .defaultBackground,
        underlineColor: TerminalColor? = nil,
        flags: Flags = [],
        hyperlinkID: UInt32? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.underlineColor = underlineColor
        self.flags = flags
        self.hyperlinkID = hyperlinkID
    }

    public static let `default` = CellAttributes()
}

/// One rendered cell. A wide grapheme owns a `lead` cell followed by exactly one
/// `continuation`; a combining mark never becomes a standalone selectable cell.
public struct TerminalCell: Hashable, Sendable {
    public enum Span: UInt8, Hashable, Sendable, Codable {
        case narrow
        case wide
        case continuation
    }

    /// The grapheme cluster, already width-resolved. Empty means blank.
    public var text: String
    public var attributes: CellAttributes
    public var span: Span

    public init(text: String, attributes: CellAttributes = .default, span: Span = .narrow) {
        self.text = text
        self.attributes = attributes
        self.span = span
    }

    public static let blank = TerminalCell(text: " ")
    public var isBlank: Bool { span != .continuation && (text.isEmpty || text == " ") }
}

/// OSC 133 command-region phases. `A` prompt start, `B` input start, `C`
/// output start, `D` command finished with exit code.
public enum CommandPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case promptStart = "A"
    case inputStart = "B"
    case outputStart = "C"
    case finished = "D"
}

/// One shell command region reduced from OSC 133, used by the board, router,
/// digest, and jump-to-prompt navigation.
public struct CommandRegion: Hashable, Sendable, Codable, Identifiable {
    public var id: LineID { promptLine }
    public var promptLine: LineID
    public var inputLine: LineID?
    public var outputLine: LineID?
    public var endLine: LineID?
    public var phase: CommandPhase
    public var exitCode: Int32?
    public var commandText: String?
    public var workingDirectory: String?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        promptLine: LineID,
        inputLine: LineID? = nil,
        outputLine: LineID? = nil,
        endLine: LineID? = nil,
        phase: CommandPhase = .promptStart,
        exitCode: Int32? = nil,
        commandText: String? = nil,
        workingDirectory: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.promptLine = promptLine
        self.inputLine = inputLine
        self.outputLine = outputLine
        self.endLine = endLine
        self.phase = phase
        self.exitCode = exitCode
        self.commandText = commandText
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isRunning: Bool { phase == .outputStart }
    public var succeeded: Bool? { exitCode.map { $0 == 0 } }
}

public struct CursorState: Hashable, Sendable, Codable {
    public enum Shape: String, Hashable, Sendable, Codable, CaseIterable {
        case block
        case underline
        case bar
    }

    public var row: Int
    public var column: Int
    public var visible: Bool
    public var shape: Shape
    /// DECAWM wrap-pending: the cursor sits past the last column but has not
    /// wrapped yet. Rendering pins it to the last cell.
    public var wrapPending: Bool

    public init(
        row: Int = 0, column: Int = 0, visible: Bool = true, shape: Shape = .block,
        wrapPending: Bool = false
    ) {
        self.row = row
        self.column = column
        self.visible = visible
        self.shape = shape
        self.wrapPending = wrapPending
    }
}

/// A stable selection anchor: a logical line identity plus a grapheme offset.
/// Never an array index, so append and reflow cannot move it (SPEC §3).
public struct SelectionAnchor: Hashable, Sendable, Codable {
    public var line: LineID
    public var graphemeOffset: Int

    public init(line: LineID, graphemeOffset: Int) {
        self.line = line
        self.graphemeOffset = graphemeOffset
    }
}

public struct Selection: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable { case stream, block }
    public var start: SelectionAnchor
    public var end: SelectionAnchor
    public var mode: Mode

    public init(start: SelectionAnchor, end: SelectionAnchor, mode: Mode = .stream) {
        self.start = start
        self.end = end
        self.mode = mode
    }
}

/// Terminal modes a renderer or input encoder must observe.
public struct TerminalModes: Hashable, Sendable, Codable {
    public var alternateScreen: Bool
    public var applicationCursorKeys: Bool
    public var applicationKeypad: Bool
    public var bracketedPaste: Bool
    public var autoWrap: Bool
    public var originMode: Bool
    public var insertMode: Bool
    public var reverseVideo: Bool
    public var mouseTracking: MouseTracking
    public var mouseEncoding: MouseEncoding
    public var focusReporting: Bool
    public var synchronizedOutput: Bool

    public init(
        alternateScreen: Bool = false,
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false,
        bracketedPaste: Bool = false,
        autoWrap: Bool = true,
        originMode: Bool = false,
        insertMode: Bool = false,
        reverseVideo: Bool = false,
        mouseTracking: MouseTracking = .off,
        mouseEncoding: MouseEncoding = .x10,
        focusReporting: Bool = false,
        synchronizedOutput: Bool = false
    ) {
        self.alternateScreen = alternateScreen
        self.applicationCursorKeys = applicationCursorKeys
        self.applicationKeypad = applicationKeypad
        self.bracketedPaste = bracketedPaste
        self.autoWrap = autoWrap
        self.originMode = originMode
        self.insertMode = insertMode
        self.reverseVideo = reverseVideo
        self.mouseTracking = mouseTracking
        self.mouseEncoding = mouseEncoding
        self.focusReporting = focusReporting
        self.synchronizedOutput = synchronizedOutput
    }
}

public enum MouseTracking: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    case press
    case pressRelease
    case buttonMotion
    case anyMotion
}

public enum MouseEncoding: String, Hashable, Sendable, Codable, CaseIterable {
    case x10
    case sgr
}

/// Row ranges that changed since the previous generation. A full redraw is
/// requested only for geometry, scale, palette, theme, or resource invalidation.
public struct Damage: Hashable, Sendable, Codable {
    public var fullRedraw: Bool
    public var rows: [Range<Int>]
    public var cursorMoved: Bool
    public var selectionChanged: Bool

    public init(
        fullRedraw: Bool = false, rows: [Range<Int>] = [], cursorMoved: Bool = false,
        selectionChanged: Bool = false
    ) {
        self.fullRedraw = fullRedraw
        self.rows = rows
        self.cursorMoved = cursorMoved
        self.selectionChanged = selectionChanged
    }

    public static let none = Damage()
    public static let full = Damage(fullRedraw: true, cursorMoved: true, selectionChanged: true)
    public var isEmpty: Bool {
        !fullRedraw && rows.isEmpty && !cursorMoved && !selectionChanged
    }
}

/// A placement in the reserved image plane. No v1 parser sequence populates
/// this; the seam exists so v1.x graphics land as an addition (SPEC §3).
public struct ImagePlacement: Hashable, Sendable {
    public var identifier: UInt32
    public var row: Int
    public var column: Int
    public var widthCells: Int
    public var heightCells: Int

    public init(identifier: UInt32, row: Int, column: Int, widthCells: Int, heightCells: Int) {
        self.identifier = identifier
        self.row = row
        self.column = column
        self.widthCells = widthCells
        self.heightCells = heightCells
    }
}

/// One coherent, immutable terminal generation.
public struct TerminalSnapshot: Sendable {
    public var generation: Generation
    public var geometry: TerminalGeometry
    /// Materialized viewport rows, `geometry.rows` of `geometry.columns` cells.
    public var rows: [[TerminalCell]]
    /// Stable identity of each viewport row, for anchors and accessibility.
    public var rowIDs: [LineID]
    public var cursor: CursorState
    public var modes: TerminalModes
    public var selection: Selection?
    public var damage: Damage
    public var title: String?
    /// Rows scrolled off above the viewport, for scrollbar geometry.
    public var scrollbackCount: Int
    /// Viewport offset above the live bottom, in rows. Zero means pinned.
    public var scrollOffset: Int
    public var commandRegions: [CommandRegion]
    /// Always empty in v1; the ordered plane behind glyphs is reserved.
    public var imagePlacements: [ImagePlacement]

    public init(
        generation: Generation,
        geometry: TerminalGeometry,
        rows: [[TerminalCell]],
        rowIDs: [LineID],
        cursor: CursorState,
        modes: TerminalModes,
        selection: Selection? = nil,
        damage: Damage = .full,
        title: String? = nil,
        scrollbackCount: Int = 0,
        scrollOffset: Int = 0,
        commandRegions: [CommandRegion] = [],
        imagePlacements: [ImagePlacement] = []
    ) {
        self.generation = generation
        self.geometry = geometry
        self.rows = rows
        self.rowIDs = rowIDs
        self.cursor = cursor
        self.modes = modes
        self.selection = selection
        self.damage = damage
        self.title = title
        self.scrollbackCount = scrollbackCount
        self.scrollOffset = scrollOffset
        self.commandRegions = commandRegions
        self.imagePlacements = imagePlacements
    }

    /// Plain text of one viewport row, with continuation cells collapsed.
    public func plainText(row index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        var text = ""
        for cell in rows[index] where cell.span != .continuation {
            text += cell.text.isEmpty ? " " : cell.text
        }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
