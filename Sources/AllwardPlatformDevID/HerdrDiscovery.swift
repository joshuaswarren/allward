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
    /// The host a herdr running *in one of our own panes* is attached to.
    public static func attachedHost() async -> HostAlias? {
        let table = await processTable()
        return attachedHost(
            processTable: table, rootPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Only herdr processes descended from this application count.
    ///
    /// Scanning the whole machine was wrong and shipped a real fault: a herdr
    /// client left running in some other terminal was picked up by a freshly
    /// launched Allward, which then listed that session's panes on the Board.
    /// They could not be teleported to, because they belong to a window
    /// Allward has nothing to do with. A pane is ours if we spawned the shell
    /// it runs in, so ancestry is the test.
    static func attachedHost(processTable: String, rootPID: Int32) -> HostAlias? {
        var parents: [Int32: Int32] = [:]
        var candidates: [(pid: Int32, arguments: [String])] = []
        for line in processTable.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1])
            else { continue }
            parents[pid] = ppid
            let arguments = Array(fields.dropFirst(2))
            if arguments.contains(where: isHerdrCommand) {
                candidates.append((pid, arguments))
            }
        }
        var localServer = false
        for candidate in candidates
        where descends(candidate.pid, from: rootPID, parents: parents) {
            if let host = remoteTarget(in: candidate.arguments) {
                return HostAlias(rawValue: host)
            }
            if candidate.arguments.contains("server") { localServer = true }
        }
        return localServer ? HostAlias(rawValue: "localhost") : nil
    }

    /// Walks up the process tree, bounded so a cycle cannot hang the caller.
    static func descends(_ pid: Int32, from root: Int32, parents: [Int32: Int32]) -> Bool {
        var current = pid
        for _ in 0 ..< 64 {
            if current == root { return true }
            guard let parent = parents[current], parent != current, parent > 0 else { return false }
            current = parent
        }
        return false
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

    static func processTable() async -> String {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,ppid=,args="]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do { try process.run() } catch { return "" }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
