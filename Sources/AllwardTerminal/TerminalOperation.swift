import Foundation

public enum C0Control: UInt8, Hashable, Sendable {
    case bell = 0x07
    case backspace = 0x08
    case horizontalTab = 0x09
    case lineFeed = 0x0A
    case verticalTab = 0x0B
    case formFeed = 0x0C
    case carriageReturn = 0x0D
    case shiftOut = 0x0E
    case shiftIn = 0x0F
}

public enum EraseMode: Int, Hashable, Sendable {
    case after = 0
    case before = 1
    case all = 2
    case scrollback = 3
}

public enum TabClearMode: Int, Hashable, Sendable {
    case current = 0
    case all = 3
}

public enum TerminalMode: Int, Hashable, Sendable {
    case applicationCursorKeys = 1
    case origin = 6
    case autoWrap = 7
    case cursorBlink = 12
    case cursorVisible = 25
    case alternateScreen = 47
    case mousePress = 1000
    case mouseButtonMotion = 1002
    case mouseAnyMotion = 1003
    case focusReporting = 1004
    case sgrMouse = 1006
    case alternateScreen1047 = 1047
    case saveCursor = 1048
    case alternateScreen1049 = 1049
    case bracketedPaste = 2004
    case synchronizedOutput = 2026
}

public enum SGRParameter: Hashable, Sendable {
    case reset
    case flag(CellAttributes.Flags, enabled: Bool)
    case foreground(TerminalColor)
    case background(TerminalColor)
    case underlineColor(TerminalColor?)
}

public struct OSCCommandMarker: Hashable, Sendable {
    public var phase: CommandPhase
    public var parameters: [String: String]

    public init(phase: CommandPhase, parameters: [String: String]) {
        self.phase = phase
        self.parameters = parameters
    }
}

public enum TerminalOperation: Hashable, Sendable {
    case print(String)
    case control(C0Control)
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBackward(Int)
    case cursorNextLine(Int)
    case cursorPreviousLine(Int)
    case cursorHorizontalAbsolute(Int)
    case cursorVerticalAbsolute(Int)
    case cursorPosition(row: Int, column: Int)
    case eraseDisplay(EraseMode, selective: Bool)
    case eraseLine(EraseMode, selective: Bool)
    case eraseCharacters(Int)
    case insertCharacters(Int)
    case deleteCharacters(Int)
    case insertLines(Int)
    case deleteLines(Int)
    case setInsertMode(Bool)
    case setApplicationKeypad(Bool)
    case scrollUp(Int)
    case scrollDown(Int)
    case setVerticalMargins(top: Int, bottom: Int)
    case ignoreHorizontalMargins
    case saveCursor
    case restoreCursor
    case sgr([SGRParameter])
    case setModes([TerminalMode])
    case resetModes([TerminalMode])
    case setTabStop
    case clearTabStop(TabClearMode)
    case cursorForwardTab(Int)
    case cursorBackwardTab(Int)
    case setTitle(String)
    case setWorkingDirectory(String)
    case setHyperlink(parameters: String, uri: String?)
    case commandMarker(OSCCommandMarker)
    case setPalette(index: UInt8, value: String)
    case setDynamicColor(slot: Int, value: String)
    case respond([UInt8])
    case reset
    case reportCursorPosition(privateMode: Bool)
    case alignmentTest
    case index
    case reverseIndex
    case nextLine
    case setProtection(Bool)
    case noOp
}
