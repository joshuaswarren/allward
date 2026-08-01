import AllwardCore
import Foundation

/// Finds the herdr a person is actually using.
///
/// The adapter used to be built only when a Room declared an adapter server,
/// and nothing in the interface can declare one - so Integrations reported "no
/// herdr" to everyone, permanently, including while a herdr session was running
/// in a pane. Connecting with `herdr --remote <host>` is the normal way in, and
/// it left no trace Allward ever looked at.
///
/// So the running processes are the source of truth: a `herdr --remote <host>`
/// client names the host its panes live on, and a local `herdr server` names
/// this machine. Configuration still wins when it is present, because naming a
/// host in a Room is a deliberate statement.
public enum HerdrDiscovery {
    /// The host a running herdr client or server is attached to.
    public static func attachedHost() -> HostAlias? {
        attachedHost(processTable: processTable())
    }

    static func attachedHost(processTable: String) -> HostAlias? {
        var localServer = false
        for line in processTable.split(whereSeparator: \.isNewline) {
            let arguments = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard arguments.contains(where: isHerdrCommand) else { continue }
            if let host = remoteTarget(in: arguments) { return HostAlias(rawValue: host) }
            if arguments.contains("server") { localServer = true }
        }
        return localServer ? HostAlias(rawValue: "localhost") : nil
    }

    /// `--remote <target>` or `--remote=<target>`; `-` is a flag, not a host.
    static func remoteTarget(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--remote=") {
                let value = String(argument.dropFirst("--remote=".count))
                return value.isEmpty ? nil : value
            }
            guard argument == "--remote", index + 1 < arguments.count else { continue }
            let value = arguments[index + 1]
            return value.hasPrefix("-") ? nil : value
        }
        return nil
    }

    /// The executable is `herdr`, not merely a command line mentioning it - a
    /// shell editing this file would otherwise look like a herdr session.
    static func isHerdrCommand(_ argument: String) -> Bool {
        guard !argument.hasPrefix("-") else { return false }
        let name = (argument as NSString).lastPathComponent
        return name == "herdr"
    }

    static func processTable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
