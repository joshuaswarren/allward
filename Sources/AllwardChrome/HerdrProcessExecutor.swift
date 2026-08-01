import AllwardCore
import AllwardHerdr
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
/// Runs herdr's CLI for the adapter.
///
/// The adapter deliberately owns no process launching: it produces an argv and
/// this executor runs it, so a sandboxed target can supply a different one (or
/// none) without touching adapter logic.
public enum HerdrProcessExecutor {
    public static func makeClient(for endpoint: HerdrEndpoint) -> HerdrSocketClient {
        HerdrSocketClient(endpoint: endpoint, executor: execute)
    }

    /// Resolves the adapter endpoint from the Rooms that declare adapter
    /// servers. Absent configuration means no adapter, never a guessed host.
    public static func endpoint(host: HostAlias?) -> HerdrEndpoint? {
        guard let host else { return nil }
        let localNames: Set<String> = [
            "localhost", "127.0.0.1", ProcessInfo.processInfo.hostName,
        ]
        return HerdrEndpoint(
            host: host,
            executionSite: localNames.contains(host.rawValue) ? .local : .ssh)
    }
    private final class ProcessExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var isDone = false
        private let continuation: CheckedContinuation<Data, Error>
        let process: Process

        init(continuation: CheckedContinuation<Data, Error>, process: Process) {
            self.continuation = continuation
            self.process = process
        }

        func resume(with result: Result<Data, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !isDone else { return }
            isDone = true
            continuation.resume(with: result)
        }

        func killProcess() {
            if process.isRunning {
                process.terminate()
                if process.processIdentifier > 0 {
                    kill(pid_t(process.processIdentifier), SIGKILL)
                }
            }
        }
    }

    private static let execute: HerdrCommandExecutor = { argv in
        guard let executable = argv.first else {
            throw AllwardError(
                domain: .adapter, operation: "herdr-exec", cause: "empty argument vector",
                recovery: "Reconfigure the adapter endpoint")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = ProcessExecutionState(continuation: continuation, process: process)

                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    state.killProcess()
                    state.resume(with: .failure(HerdrClientError.timedOut(argv: argv)))
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutTask.cancel()
                    if process.terminationStatus == 0 {
                        state.resume(with: .success(data))
                    } else {
                        let cause =
                            String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                        state.resume(
                            with: .failure(HerdrClientError.commandFailed(argv: argv, cause: cause)))
                    }
                }
            }
        } onCancel: {
            // A cancelled adapter refresh must not leave a herdr child running.
            if process.isRunning {
                process.terminate()
                if process.processIdentifier > 0 {
                    kill(pid_t(process.processIdentifier), SIGKILL)
                }
            }
        }
    }
}
