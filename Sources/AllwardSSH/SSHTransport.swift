import AllwardCore
import AllwardLocalPTY
import AllwardRemote
import Darwin
import Foundation

private actor SSHAttemptReadiness {
    struct Changes: Sendable {
        var authenticating: Bool
        var ready: Bool
    }

    private var authenticating = false
    private var ready = false

    func markAuthenticating() -> Bool {
        guard !authenticating else { return false }
        authenticating = true
        return true
    }

    func markReady() -> Changes {
        let changes = Changes(authenticating: !authenticating, ready: !ready)
        authenticating = true
        ready = true
        return changes
    }

    func value() -> Bool {
        ready
    }
}

public enum SSHFailureKind: Hashable, Sendable {
    case trustDenied
    case nonretryable
    case retryable
}

public enum SSHFailureClassifier {
    public static func classify(_ text: String) -> SSHFailureKind? {
        let message = text.lowercased()
        if message.contains("remote host identification has changed")
            || message.contains("host key verification failed")
            || message.contains("host key mismatch")
            || message.contains("permission denied")
        {
            return .trustDenied
        }
        if message.contains("could not resolve hostname") {
            return .nonretryable
        }
        if message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
        {
            return .retryable
        }
        return nil
    }

    static func classifyFinalDiagnostic(_ text: String) -> SSHFailureKind? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for line in lines {
            if line.contains("remote host identification has changed")
                || line.contains("host key verification failed")
                || line.contains("host key mismatch")
            {
                return .trustDenied
            }
            if line.hasPrefix("permission denied")
                || (line.contains("@") && line.contains(": permission denied"))
            {
                return .trustDenied
            }
            guard line.hasPrefix("ssh:") else { continue }
            if line.contains("could not resolve hostname") { return .nonretryable }
            if line.contains("connection refused")
                || line.contains("connection timed out")
                || line.contains("operation timed out")
            {
                return .retryable
            }
        }
        return nil
    }
}

public enum SSHCommandBuilder {
    public static func arguments(
        destination: RemoteDestination,
        bound: AttemptBound,
        diagnosticLogPath: String? = nil
    ) throws -> [String] {
        guard destination.kind == .ssh, let host = destination.host else {
            throw AllwardError(
                domain: .transport,
                operation: "build SSH command",
                cause: "SSH destination has no host alias",
                retryability: .nonretryable,
                recovery: "Choose a configured SSH host alias."
            )
        }

        let connectTimeout = max(1, Int(ceil(bound.perAttemptTimeout)))
        var arguments = [
            "ssh",
            "-tt",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]

        if let diagnosticLogPath {
            guard !diagnosticLogPath.contains("\0") else {
                throw AllwardError(
                    domain: .transport,
                    operation: "build SSH command",
                    cause: "diagnostic log path contains a null byte",
                    retryability: .nonretryable,
                    recovery: "Use an app-owned runtime path."
                )
            }
            arguments.append(contentsOf: [
                "-o", "LogLevel=DEBUG1",
                "-E", diagnosticLogPath,
            ])
        }
        if diagnosticLogPath != nil, let command = destination.command, !command.isEmpty {
            arguments.append(contentsOf: [
                "-o", "ControlMaster=no",
                "-o", "ControlPath=none",
            ])
        }
        arguments.append(host.rawValue)

        if let socket = destination.environment["ALLWARD_SOCKET"] {
            guard !socket.contains("\0") else {
                throw AllwardError(
                    domain: .transport,
                    operation: "build SSH command",
                    cause: "ALLWARD_SOCKET contains a null byte",
                    retryability: .nonretryable,
                    recovery: "Issue a valid remote socket path."
                )
            }
            let socketAssignment = "ALLWARD_SOCKET=\(shellQuote(socket))"
            if let command = destination.command, !command.isEmpty {
                arguments.append(
                    "env \(socketAssignment) " + command.map(shellQuote).joined(separator: " ")
                )
            } else {
                arguments.append("env \(socketAssignment) \"${SHELL:-/bin/sh}\" -l")
            }
        } else if let command = destination.command, !command.isEmpty {
            arguments.append(command.map(shellQuote).joined(separator: " "))
        }
        return arguments
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct SSHTransport: RemoteTransport {
    private let localPTY: LocalPTYTransport

    public init(localPTY: LocalPTYTransport = LocalPTYTransport()) {
        self.localPTY = localPTY
    }

    public func supports(_ destination: RemoteDestination) -> Bool {
        destination.kind == .ssh && destination.host != nil
    }

    public func open(
        _ destination: RemoteDestination,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound
    ) async throws -> any RemoteChannel {
        guard supports(destination) else {
            throw AllwardError(
                domain: .transport,
                operation: "open SSH",
                cause: "destination is not a configured SSH host",
                retryability: .nonretryable,
                recovery: "Choose a configured SSH host alias."
            )
        }
        guard !Task.isCancelled else {
            throw AllwardError(
                domain: .transport,
                operation: "open SSH",
                cause: "connection was cancelled",
                retryability: .cancelled,
                recovery: "Start a new connection when ready."
            )
        }

        _ = try SSHCommandBuilder.arguments(destination: destination, bound: bound)
        let id = ConnectionID()
        let diagnosticDirectory = AllwardPaths.runtimeDirectory()
            .appendingPathComponent("ssh-diagnostics", isDirectory: true)
            .appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: diagnosticDirectory,
                withIntermediateDirectories: true
            )
            guard Darwin.chmod(diagnosticDirectory.path, mode_t(0o700)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            throw AllwardError(
                domain: .transport,
                operation: "prepare SSH diagnostics",
                cause: String(describing: error),
                retryability: .nonretryable,
                recovery: "Check the app runtime directory permissions."
            )
        }
        let channel = SSHChannel(
            id: id,
            destination: destination,
            geometry: geometry,
            bound: bound,
            localPTY: localPTY,
            diagnosticDirectory: diagnosticDirectory
        )
        channel.start()
        return channel
    }
}

public final class SSHChannel: RemoteChannel, @unchecked Sendable {
    private struct Lifecycle {
        var current: LocalPTYChannel?
        var geometry: (columns: Int, rows: Int)
        var state: ConnectionState = .idle
        var closing = false
        var streamFinished = false
        var supervisor: Task<Void, Never>?
    }

    private enum AttemptOutcome: Sendable {
        case succeeded(Int32?)
        case failed(SSHFailureKind, String, wasReady: Bool)
        case timedOut(wasReady: Bool)
        case cancelled
    }

    private enum ObservationSignal: Sendable {
        case outcome(AttemptOutcome)
        case timerReached(ready: Bool)
    }

    public let id: ConnectionID
    public let destination: RemoteDestination
    public let events: AsyncStream<RemoteEvent>

    private let eventBuffer: RemoteEventBuffer
    private let lifecycleLock = NSLock()
    private var lifecycle: Lifecycle
    private let bound: AttemptBound
    private let localPTY: LocalPTYTransport
    private let diagnosticDirectory: URL

    // The protocol requires synchronous control methods; the lock fences channel replacement and terminal state.
    init(
        id: ConnectionID,
        destination: RemoteDestination,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound,
        localPTY: LocalPTYTransport,
        diagnosticDirectory: URL
    ) {
        self.id = id
        self.destination = destination
        self.bound = bound
        self.localPTY = localPTY
        self.diagnosticDirectory = diagnosticDirectory
        let buffer = RemoteEventBuffer()
        events = buffer.stream
        eventBuffer = buffer
        lifecycle = Lifecycle(geometry: geometry)
    }

    deinit {
        close()
    }

    func start() {
        let task = Task { [self] in
            await supervise()
        }
        lifecycleLock.withLock {
            guard lifecycle.supervisor == nil, !lifecycle.closing else {
                task.cancel()
                return
            }
            lifecycle.supervisor = task
        }
    }

    public func write(_ bytes: [UInt8]) {
        lifecycleLock.withLock { lifecycle.current }?.write(bytes)
    }

    public func resize(columns: Int, rows: Int) {
        let current = lifecycleLock.withLock { () -> LocalPTYChannel? in
            lifecycle.geometry = (columns, rows)
            return lifecycle.current
        }
        current?.resize(columns: columns, rows: rows)
    }

    public func close() {
        let resources = lifecycleLock.withLock { () -> (LocalPTYChannel?, Task<Void, Never>?)? in
            guard !lifecycle.closing && !lifecycle.streamFinished else { return nil }
            lifecycle.closing = true
            lifecycle.state = .closed(.explicit)
            lifecycle.streamFinished = true
            eventBuffer.send(.state(.closed(.explicit), nil))
            eventBuffer.finish()
            return (lifecycle.current, lifecycle.supervisor)
        }
        guard let resources else { return }
        resources.1?.cancel()
        resources.0?.close()
        removeDiagnosticDirectory()
    }

    private func supervise() async {
        transition(to: .idle, progress: nil)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(bound.totalTimeout))
        var lastCause = "SSH connection failed"

        for attempt in 1...bound.maxAttempts {
            if Task.isCancelled || isClosing { return }
            if clock.now >= deadline {
                finishFailure(cause: "SSH connection exceeded its total timeout")
                return
            }

            let resolving = AttemptProgress(
                attempt: attempt,
                bound: bound,
                step: "resolving \(hostName)"
            )
            transition(to: .resolving, progress: resolving)

            let arguments: [String]
            let diagnosticWatcher: SSHDiagnosticLogWatcher
            do {
                let diagnosticURL = diagnosticDirectory
                    .appendingPathComponent("attempt-\(attempt).log", isDirectory: false)
                diagnosticWatcher = try SSHDiagnosticLogWatcher(fileURL: diagnosticURL)
                arguments = try SSHCommandBuilder.arguments(
                    destination: destination,
                    bound: bound,
                    diagnosticLogPath: diagnosticURL.path
                )
            } catch let error as AllwardError {
                finish(kind: .nonretryable, cause: error.cause)
                return
            } catch {
                finish(kind: .nonretryable, cause: String(describing: error))
                return
            }

            let geometry = lifecycleLock.withLock { lifecycle.geometry }
            let process: LocalPTYChannel
            do {
                var environment = ProcessInfo.processInfo.environment
                environment["TERM"] = "xterm-256color"
                environment["COLORTERM"] = "truecolor"
                environment["ALLWARD"] = "1"
                let configuration = LocalPTYProcessConfiguration(
                    executable: "/usr/bin/ssh",
                    arguments: arguments,
                    environment: environment,
                    destination: destination
                )
                process = try localPTY.openProcess(configuration, geometry: geometry)
            } catch let error as AllwardError {
                diagnosticWatcher.close()
                lastCause = error.cause
                let willRetry = await retry(
                    after: attempt,
                    wasReady: false,
                    cause: lastCause,
                    deadline: deadline
                )
                if !willRetry {
                    finishFailure(cause: lastCause)
                    return
                }
                continue
            } catch {
                diagnosticWatcher.close()
                lastCause = String(describing: error)
                let willRetry = await retry(
                    after: attempt,
                    wasReady: false,
                    cause: lastCause,
                    deadline: deadline
                )
                if !willRetry {
                    finishFailure(cause: lastCause)
                    return
                }
                continue
            }

            setCurrent(process)
            let connecting = AttemptProgress(
                attempt: attempt,
                bound: bound,
                step: "connecting to \(hostName)"
            )
            transition(to: .connecting, progress: connecting)
            let perAttempt = min(
                Duration.seconds(bound.perAttemptTimeout),
                clock.now.duration(to: deadline)
            )
            let outcome = await observe(
                process,
                diagnosticWatcher: diagnosticWatcher,
                attempt: attempt,
                timeout: perAttempt
            )
            diagnosticWatcher.close()
            clearCurrent(process)

            switch outcome {
            case let .succeeded(code):
                finishSuccess(code: code)
                return
            case let .failed(.trustDenied, cause, _):
                finish(kind: .trustDenied, cause: cause)
                return
            case let .failed(.nonretryable, cause, _):
                finish(kind: .nonretryable, cause: cause)
                return
            case let .failed(.retryable, cause, wasReady):
                lastCause = cause
                let willRetry = await retry(
                    after: attempt,
                    wasReady: wasReady,
                    cause: cause,
                    deadline: deadline
                )
                if !willRetry {
                    finishFailure(cause: cause)
                    return
                }
            case let .timedOut(wasReady):
                lastCause = "connection to \(hostName) timed out"
                process.close()
                let willRetry = await retry(
                    after: attempt,
                    wasReady: wasReady,
                    cause: lastCause,
                    deadline: deadline
                )
                if !willRetry {
                    finishFailure(cause: lastCause)
                    return
                }
            case .cancelled:
                return
            }
        }

        finishFailure(cause: lastCause)
    }

    private func observe(
        _ process: LocalPTYChannel,
        diagnosticWatcher: SSHDiagnosticLogWatcher,
        attempt: Int,
        timeout: Duration
    ) async -> AttemptOutcome {
        let readiness = SSHAttemptReadiness()
        return await withTaskGroup(of: ObservationSignal.self) { group in
            group.addTask { [self] in
                .outcome(
                    await consumePTY(
                        process,
                        diagnosticWatcher: diagnosticWatcher,
                        attempt: attempt,
                        readiness: readiness
                    )
                )
            }
            group.addTask { [self] in
                .outcome(
                    await consumeDiagnostics(
                        diagnosticWatcher.events,
                        process: process,
                        attempt: attempt,
                        readiness: readiness
                    )
                )
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timerReached(ready: await readiness.value())
                } catch {
                    return .outcome(.cancelled)
                }
            }

            while let signal = await group.next() {
                switch signal {
                case let .outcome(outcome):
                    group.cancelAll()
                    return outcome
                case .timerReached(ready: false):
                    group.cancelAll()
                    process.close()
                    return .timedOut(wasReady: false)
                case .timerReached(ready: true):
                    continue
                }
            }
            return .cancelled
        }
    }

    private func consumePTY(
        _ process: LocalPTYChannel,
        diagnosticWatcher: SSHDiagnosticLogWatcher,
        attempt: Int,
        readiness: SSHAttemptReadiness
    ) async -> AttemptOutcome {
        var terminalText = ""

        for await event in process.events {
            if Task.isCancelled { return .cancelled }
            switch event {
            case let .bytes(bytes):
                eventBuffer.send(.bytes(bytes))
                let chunk = String(decoding: bytes, as: UTF8.self)
                terminalText = String((terminalText + chunk).suffix(2_048))

                let lower = chunk.lowercased()
                let authenticationText = lower.contains("password:")
                    || lower.contains("passphrase for key")
                    || lower.contains("are you sure you want to continue connecting")
                if authenticationText {
                    await publishAuthenticating(readiness: readiness, attempt: attempt)
                }
            case let .exited(code):
                if let code, code != 255 {
                    await publishReady(readiness: readiness, attempt: attempt)
                    return .succeeded(code)
                }
                let finalDiagnostic = diagnosticWatcher.finalContents()
                let wasReady = await readiness.value()
                let finalLower = finalDiagnostic.lowercased()
                let completedRemoteCommand = finalLower.contains("exit status 255")
                if completedRemoteCommand {
                    return .succeeded(255)
                }
                let cause = finalDiagnostic.isEmpty
                    ? (terminalText.isEmpty
                        ? "ssh exited with status \(code.map(String.init) ?? "signal")"
                        : boundedDiagnostic(terminalText))
                    : boundedDiagnostic(finalDiagnostic)
                let kind = SSHFailureClassifier.classifyFinalDiagnostic(finalDiagnostic) ?? .retryable
                return .failed(kind, cause, wasReady: wasReady)
            case let .failed(error):
                return .failed(.retryable, error.cause, wasReady: await readiness.value())
            case .state:
                continue
            }
        }

        return Task.isCancelled
            ? .cancelled
            : .failed(
                .retryable,
                "ssh channel ended without an exit status",
                wasReady: await readiness.value()
            )
    }

    private func consumeDiagnostics(
        _ diagnostics: AsyncStream<String>,
        process: LocalPTYChannel,
        attempt: Int,
        readiness: SSHAttemptReadiness
    ) async -> AttemptOutcome {
        var diagnostic = ""
        for await chunk in diagnostics {
            if Task.isCancelled { return .cancelled }
            diagnostic = String((diagnostic + chunk).suffix(8_192))
            let isReady = await readiness.value()
            if !isReady, let kind = SSHFailureClassifier.classifyFinalDiagnostic(diagnostic) {
                process.close()
                return .failed(kind, boundedDiagnostic(diagnostic), wasReady: false)
            }

            let lower = diagnostic.lowercased()
            if lower.contains("authenticating to ") || lower.contains("authenticated to ") {
                await publishAuthenticating(readiness: readiness, attempt: attempt)
            }
            if lower.contains("entering interactive session")
                || lower.contains("mux_client_request_session: master session id")
            {
                await publishReady(readiness: readiness, attempt: attempt)
            }
        }
        return .cancelled
    }

    private func publishAuthenticating(
        readiness: SSHAttemptReadiness,
        attempt: Int
    ) async {
        if await readiness.markAuthenticating() {
            transitionToAuthenticating(attempt: attempt)
        }
    }

    private func publishReady(
        readiness: SSHAttemptReadiness,
        attempt: Int
    ) async {
        let changes = await readiness.markReady()
        if changes.authenticating {
            transitionToAuthenticating(attempt: attempt)
        }
        if changes.ready {
            transition(to: .ready, progress: nil)
        }
    }

    private func retry(
        after attempt: Int,
        wasReady: Bool,
        cause _: String,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        guard attempt < bound.maxAttempts else { return false }
        let delay = Duration.seconds(bound.backoff(afterAttempt: attempt))
        let clock = ContinuousClock()
        guard clock.now.advanced(by: delay) < deadline else { return false }

        let progress = AttemptProgress(
            attempt: attempt + 1,
            bound: bound,
            step: "waiting to retry \(hostName)"
        )
        transition(to: wasReady ? .reconnecting : .resolving, progress: progress)
        do {
            try await Task.sleep(for: delay)
            return !isClosing
        } catch {
            return false
        }
    }

    private var hostName: String {
        destination.host?.rawValue ?? "host"
    }

    private var isClosing: Bool {
        lifecycleLock.withLock { lifecycle.closing }
    }

    private func transitionToAuthenticating(attempt: Int) {
        transition(
            to: .authenticating,
            progress: AttemptProgress(
                attempt: attempt,
                bound: bound,
                step: "authenticating with \(hostName)"
            )
        )
    }

    private func setCurrent(_ process: LocalPTYChannel) {
        let shouldClose = lifecycleLock.withLock { () -> Bool in
            guard !lifecycle.closing else { return true }
            lifecycle.current = process
            return false
        }
        if shouldClose { process.close() }
    }

    private func clearCurrent(_ process: LocalPTYChannel) {
        lifecycleLock.withLock {
            if lifecycle.current === process { lifecycle.current = nil }
        }
    }

    private func transition(to state: ConnectionState, progress: AttemptProgress?) {
        lifecycleLock.withLock {
            guard !lifecycle.closing && !lifecycle.streamFinished else { return }
            lifecycle.state = state
            eventBuffer.send(.state(state, progress))
        }
    }

    private func finishSuccess(code: Int32?) {
        let shouldFinish = markFinished(state: .closed(.explicit))
        guard shouldFinish else { return }
        eventBuffer.send(.exited(code: code))
        eventBuffer.send(.state(.closed(.explicit), nil))
        eventBuffer.finish()
        removeDiagnosticDirectory()
    }

    private func finish(kind: SSHFailureKind, cause: String) {
        switch kind {
        case .trustDenied:
            guard markFinished(state: .closed(.trustDenied)) else { return }
            eventBuffer.send(.failed(error(cause: cause, retryability: .trustDenied)))
            eventBuffer.send(.state(.closed(.trustDenied), nil))
        case .nonretryable, .retryable:
            guard markFinished(state: .closed(.nonretryable)) else { return }
            eventBuffer.send(.failed(error(cause: cause, retryability: .nonretryable)))
            eventBuffer.send(.state(.closed(.nonretryable), nil))
        }
        eventBuffer.finish()
        removeDiagnosticDirectory()
    }

    private func finishFailure(cause: String) {
        finish(kind: .nonretryable, cause: cause)
    }

    private func markFinished(state: ConnectionState) -> Bool {
        lifecycleLock.withLock {
            guard !lifecycle.closing && !lifecycle.streamFinished else { return false }
            lifecycle.state = state
            lifecycle.streamFinished = true
            lifecycle.current = nil
            return true
        }
    }

    private func removeDiagnosticDirectory() {
        try? FileManager.default.removeItem(at: diagnosticDirectory)
    }

    private func error(
        cause: String,
        retryability: AllwardError.Retryability
    ) -> AllwardError {
        AllwardError(
            domain: .transport,
            operation: "connect to \(hostName)",
            cause: cause,
            retryability: retryability,
            recovery: retryability == .trustDenied
                ? "Review the host key or credentials before reconnecting."
                : "Check the host configuration and retry."
        )
    }

    private func boundedDiagnostic(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.suffix(3).joined(separator: " ")
    }
}
