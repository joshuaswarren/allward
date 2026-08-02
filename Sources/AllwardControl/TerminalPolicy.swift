/// What a program running in a pane is allowed to do beyond drawing.
///
/// Two xterm sequences reach outside the terminal: `OSC 46` writes to a path
/// the program chooses, and an `OSC 52` read hands back whatever the user last
/// copied. Both are implemented, and both are off unless the configuration
/// turns them on, because a program that can do either without asking is a
/// hole rather than a feature.
public struct TerminalPolicy: Hashable, Sendable {
    public var allowLogFile: Bool
    public var allowClipboardRead: Bool

    public init(allowLogFile: Bool = false, allowClipboardRead: Bool = false) {
        self.allowLogFile = allowLogFile
        self.allowClipboardRead = allowClipboardRead
    }
}
