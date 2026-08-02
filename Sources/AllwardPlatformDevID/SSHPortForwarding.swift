import AllwardCore
import AllwardLocalPTY
import AllwardRemote
import Darwin
import Foundation

public typealias SSHAuthenticationResponder = @Sendable (String) async -> String?

private func containsSSHAuthenticationPrompt(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("password:")
        || lower.contains("passphrase for key")
        || lower.contains("are you sure you want to continue connecting")
}

public actor SSHPortForwarding {
    private enum ActiveForward {
        case control(specification: String)
        case dedicated(LocalPTYChannel)
    }

    private struct ForwardRequest: Hashable, Sendable {
        var host: HostAlias
        var localSocketPath: String
        var receiverIssuedName: String
        var bound: AttemptBound
    }

    private struct InFlightForward {
        var task: Task<ForwardedEndpoint, Error>
        var waiters: [UUID: CheckedContinuation<ForwardedEndpoint, Error>]
        var canceling = false
    }

    private struct CommandResult: Sendable {
        var code: Int32?
        var output: String
    }

    private enum CommandRace: Sendable {
        case result(CommandResult)
        case timeout
    }

    private enum ForwardReadiness: Sendable {
        case ready
        case exited(CommandResult)
        case denied(String)
        case failed(String)
        case timeout
    }

    private let localPTY: LocalPTYTransport
    private let authenticationResponder: SSHAuthenticationResponder?
    private var active: [ForwardedEndpoint: ActiveForward] = [:]
    private var monitors: [ForwardedEndpoint: Task<Void, Never>] = [:]
    private var inFlight: [ForwardRequest: InFlightForward] = [:]
    public init(
        localPTY: LocalPTYTransport = LocalPTYTransport(),
        authenticationResponder: SSHAuthenticationResponder? = nil
    ) {
        self.localPTY = localPTY
        self.authenticationResponder = authenticationResponder
    }

    public func establish(
        host: HostAlias,
        localSocketPath: String,
        receiverIssuedName: String,
        bound: AttemptBound = .connect
    ) async throws -> ForwardedEndpoint {
        let request = ForwardRequest(
            host: host,
            localSocketPath: localSocketPath,
            receiverIssuedName: receiverIssuedName,
            bound: bound
        )
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    request: request,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(request: request, waiterID: waiterID) }
        }
    }

    private func register(
        request: ForwardRequest,
        waiterID: UUID,
        continuation: CheckedContinuation<ForwardedEndpoint, Error>
    ) {
        if var existing = inFlight[request] {
            existing.waiters[waiterID] = continuation
            inFlight[request] = existing
            return
        }
        start(request: request, waiters: [waiterID: continuation])
    }

    private func start(
        request: ForwardRequest,
        waiters: [UUID: CheckedContinuation<ForwardedEndpoint, Error>]
    ) {
        let operation = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let endpoint = try await establishNew(
                    host: request.host,
                    localSocketPath: request.localSocketPath,
                    receiverIssuedName: request.receiverIssuedName,
                    bound: request.bound
                )
                await complete(request: request, result: .success(endpoint))
                return endpoint
            } catch {
                await complete(request: request, result: .failure(error))
                throw error
            }
        }
        inFlight[request] = InFlightForward(task: operation, waiters: waiters)
    }

    private func cancel(request: ForwardRequest, waiterID: UUID) async {
        guard var existing = inFlight[request],
            let continuation = existing.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(throwing: CancellationError())
        if existing.waiters.isEmpty {
            existing.canceling = true
            inFlight[request] = existing
            existing.task.cancel()
            if let endpoint = try? await existing.task.value {
                try? await close(endpoint)
            }
            guard let pending = inFlight[request], pending.canceling else { return }
            if pending.waiters.isEmpty {
                inFlight.removeValue(forKey: request)
            } else {
                start(request: request, waiters: pending.waiters)
            }
        } else {
            inFlight[request] = existing
        }
    }

    private func complete(
        request: ForwardRequest,
        result: Result<ForwardedEndpoint, Error>
    ) {
        guard let completed = inFlight[request], !completed.canceling else { return }
        inFlight.removeValue(forKey: request)
        for continuation in completed.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func establishNew(
        host: HostAlias,
        localSocketPath: String,
        receiverIssuedName: String,
        bound: AttemptBound
    ) async throws -> ForwardedEndpoint {
        try validate(localSocketPath: localSocketPath, receiverIssuedName: receiverIssuedName)
        let deadline = ContinuousClock().now.advanced(by: .seconds(bound.totalTimeout))
        let remoteSocketPath = try await issueRemotePath(
            host: host,
            receiverIssuedName: receiverIssuedName,
            bound: bound,
            deadline: deadline
        )
        let endpoint = ForwardedEndpoint(
            remoteSocketPath: remoteSocketPath,
            localSocketPath: localSocketPath,
            host: host
        )
        try Task.checkCancellation()
        if let existing = active[endpoint] {
            switch existing {
            case .dedicated:
                return endpoint
            case .control:
                let checkArguments = ["ssh", "-O", "check", host.rawValue]
                let timeout = try remainingTimeout(until: deadline, bound: bound)
                if let result = try? await runCommand(
                    arguments: checkArguments,
                    destination: .ssh(host),
                    timeout: timeout
                ), result.code == 0 {
                    return endpoint
                }
                active.removeValue(forKey: endpoint)
            }
        }

        let specification = "\(remoteSocketPath):\(localSocketPath)"
        let controlArguments = [
            "ssh",
            "-o", "StreamLocalBindMask=0177",
            "-o", "StreamLocalBindUnlink=yes",
            "-R", specification,
            "-O", "forward",
            host.rawValue,
        ]
        let controlTimeout = try remainingTimeout(until: deadline, bound: bound)
        let control = try await runCommand(
            arguments: controlArguments,
            destination: .ssh(host),
            timeout: controlTimeout
        )
        if Task.isCancelled {
            await rollbackControlForward(specification: specification, host: host, bound: bound)
            throw CancellationError()
        }
        if control.code == 0 {
            do {
                try await secureRemoteSocket(endpoint, bound: bound, deadline: deadline)
                try Task.checkCancellation()
            } catch {
                await rollbackControlForward(specification: specification, host: host, bound: bound)
                throw error
            }
            active[endpoint] = .control(specification: specification)
            return endpoint
        }
        guard indicatesMissingControlMaster(control.output) else {
            throw forwardingError(
                operation: "forward Allward endpoint",
                cause: control.output.isEmpty ? "SSH control forward failed" : control.output,
                retryability: classify(control.output),
                recovery: "Check the SSH control connection and forwarding policy."
            )
        }

        let dedicatedTimeout = try remainingTimeout(until: deadline, bound: bound)
        let connectTimeout = max(1, Int(ceil(dedicatedTimeout)))
        let dedicatedArguments = [
            "ssh",
            "-v",
            "-N",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindMask=0177",
            "-o", "StreamLocalBindUnlink=yes",
            "-R", specification,
            host.rawValue,
        ]
        let channel = try spawn(arguments: dedicatedArguments, destination: .ssh(host))
        let readiness = await awaitForwardReadiness(channel, timeout: dedicatedTimeout)
        switch readiness {
        case .ready:
            do {
                try await secureRemoteSocket(endpoint, bound: bound, deadline: deadline)
                try Task.checkCancellation()
            } catch {
                channel.close()
                throw error
            }
            active[endpoint] = .dedicated(channel)
            monitors[endpoint] = Task { [weak self] in
                for await _ in channel.events {
                    if Task.isCancelled { return }
                }
                await self?.forwardEnded(endpoint)
            }
            return endpoint
        case let .denied(cause):
            channel.close()
            throw forwardingError(
                operation: "forward Allward endpoint",
                cause: cause,
                retryability: .trustDenied,
                recovery: "Review the host key or credentials before reconnecting."
            )
        case let .failed(cause):
            channel.close()
            throw forwardingError(
                operation: "forward Allward endpoint",
                cause: cause,
                retryability: classify(cause),
                recovery: "Check the SSH forwarding policy and retry."
            )
        case let .exited(result):
            throw forwardingError(
                operation: "forward Allward endpoint",
                cause: result.output.isEmpty
                    ? "SSH forward exited with status \(result.code.map(String.init) ?? "signal")"
                    : result.output,
                retryability: classify(result.output),
                recovery: "Check the SSH forwarding policy and retry."
            )
        case .timeout:
            channel.close()
            throw forwardingError(
                operation: "forward Allward endpoint",
                cause: "SSH did not confirm the remote forward before the timeout",
                retryability: .retryable,
                recovery: "Check connectivity and retry."
            )
        }
    }

    public func close(_ endpoint: ForwardedEndpoint, bound: AttemptBound = .controlRequest) async throws {
        guard let forward = active[endpoint] else { return }
        switch forward {
        case let .dedicated(channel):
            active.removeValue(forKey: endpoint)
            monitors.removeValue(forKey: endpoint)?.cancel()
            channel.close()
        case let .control(specification):
            let arguments = [
                "ssh",
                "-R", specification,
                "-O", "cancel",
                endpoint.host.rawValue,
            ]
            let result = try await runCommand(
                arguments: arguments,
                destination: .ssh(endpoint.host),
                timeout: min(bound.perAttemptTimeout, bound.totalTimeout)
            )
            guard result.code == 0 else {
                throw forwardingError(
                    operation: "cancel Allward endpoint forward",
                    cause: result.output.isEmpty ? "SSH control cancel failed" : result.output,
                    retryability: classify(result.output),
                    recovery: "Check the SSH control connection."
                )
            }
            active.removeValue(forKey: endpoint)
        }
    }

    private func issueRemotePath(
        host: HostAlias,
        receiverIssuedName: String,
        bound: AttemptBound,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        let script = "runtime=\"${XDG_RUNTIME_DIR:-$HOME/.allward/run}\"; "
            + "umask 077; mkdir -p -m 700 \"$runtime\"; chmod 700 \"$runtime\"; "
            + "printf '%s\\n' \"$runtime/\(receiverIssuedName)\""
        let remoteCommand = "sh -lc \(shellQuote(script))"
        let timeout = try remainingTimeout(until: deadline, bound: bound)
        let connectTimeout = max(1, Int(ceil(timeout)))
        let arguments = [
            "ssh",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=\(connectTimeout)",
            host.rawValue,
            remoteCommand,
        ]
        let result = try await runCommand(
            arguments: arguments,
            destination: .ssh(host),
            timeout: timeout
        )
        guard result.code == 0 else {
            throw forwardingError(
                operation: "issue remote Allward endpoint",
                cause: result.output.isEmpty ? "remote runtime directory creation failed" : result.output,
                retryability: helperRetryability(result),
                recovery: "Check the remote account runtime directory and retry."
            )
        }

        let expectedSuffix = "/\(receiverIssuedName)"
        guard let path = result.output
            .split(whereSeparator: \.isNewline)
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { $0.hasPrefix("/") && $0.hasSuffix(expectedSuffix) })
        else {
            throw forwardingError(
                operation: "issue remote Allward endpoint",
                cause: "remote host returned no absolute runtime socket path",
                retryability: .nonretryable,
                recovery: "Check XDG_RUNTIME_DIR and the remote home directory."
            )
        }
        return path
    }

    private func secureRemoteSocket(
        _ endpoint: ForwardedEndpoint,
        bound: AttemptBound,
        deadline: ContinuousClock.Instant
    ) async throws {
        let timeout = try remainingTimeout(until: deadline, bound: bound)
        let connectTimeout = max(1, Int(ceil(timeout)))
        let command = "chmod 600 \(shellQuote(endpoint.remoteSocketPath))"
        let arguments = [
            "ssh",
            "-o", "BatchMode=no",

            "-o", "ConnectTimeout=\(connectTimeout)",
            endpoint.host.rawValue,
            command,
        ]
        let result = try await runCommand(
            arguments: arguments,
            destination: .ssh(endpoint.host),
            timeout: timeout
        )
        guard result.code == 0 else {
            throw forwardingError(
                operation: "secure remote Allward endpoint",
                cause: result.output.isEmpty ? "remote socket chmod failed" : result.output,
                retryability: helperRetryability(result),
                recovery: "Check ownership of the remote runtime socket."
            )
        }
    }
    private func rollbackControlForward(
        specification: String,
        host: HostAlias,
        bound: AttemptBound
    ) async {
        let cleanup = Task { [self] in
            let arguments = ["ssh", "-R", specification, "-O", "cancel", host.rawValue]
            return try? await runCommand(
                arguments: arguments,
                destination: .ssh(host),
                timeout: min(bound.perAttemptTimeout, bound.totalTimeout)
            )
        }
        _ = await cleanup.value
    }

    private func remainingTimeout(
        until deadline: ContinuousClock.Instant,
        bound: AttemptBound
    ) throws -> TimeInterval {
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else {
            throw forwardingError(
                operation: "establish Allward endpoint forward",
                cause: "forward establishment exceeded its total timeout",
                retryability: .retryable,
                recovery: "Check connectivity and retry."
            )
        }
        let components = remaining.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return min(bound.perAttemptTimeout, seconds)
    }

    private func runCommand(
        arguments: [String],
        destination: RemoteDestination,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let channel = try spawn(arguments: arguments, destination: destination)
        defer { channel.close() }
        let responder = authenticationResponder
        let race = await withTaskGroup(of: CommandRace.self) { group in
            group.addTask {
                var output = ""
                var code: Int32?
                var promptBuffer = ""
                for await event in channel.events {
                    switch event {
                    case let .bytes(bytes):
                        let text = String(decoding: bytes, as: UTF8.self)
                        output += text
                        if output.count > 8_192 { output = String(output.suffix(8_192)) }
                        if let responder {
                            promptBuffer = String((promptBuffer + text).suffix(1_024))
                            if containsSSHAuthenticationPrompt(promptBuffer) {
                                let prompt = promptBuffer
                                promptBuffer = ""
                                if let response = await responder(prompt) {
                                    channel.write(Array((response + "\n").utf8))
                                }
                            }
                        }
                    case let .exited(exitCode):
                        code = exitCode
                    case .failed, .state:
                        continue
                    }
                }
                return .result(CommandResult(code: code, output: output))
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    return .timeout
                } catch {
                    return .result(CommandResult(code: nil, output: "command cancelled"))
                }
            }
            let result = await group.next() ?? .timeout
            group.cancelAll()
            return result
        }
        switch race {
        case let .result(result):
            return result
        case .timeout:
            channel.close()
            throw forwardingError(
                operation: "run SSH control command",
                cause: "SSH control command timed out",
                retryability: .retryable,
                recovery: "Check connectivity and retry."
            )
        }
    }

    private func spawn(
        arguments: [String],
        destination: RemoteDestination
    ) throws -> LocalPTYChannel {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let configuration = LocalPTYProcessConfiguration(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environment,
            destination: destination
        )
        return try localPTY.openProcess(configuration, geometry: (columns: 120, rows: 40))
    }

    private func awaitForwardReadiness(
        _ channel: LocalPTYChannel,
        timeout: TimeInterval
    ) async -> ForwardReadiness {
        let responder = authenticationResponder
        return await withTaskGroup(of: ForwardReadiness.self) { group in
            group.addTask {
                var output = ""
                var code: Int32?
                var promptBuffer = ""
                for await event in channel.events {
                    if Task.isCancelled { return .failed("forward setup cancelled") }
                    switch event {
                    case let .bytes(bytes):
                        let text = String(decoding: bytes, as: UTF8.self)
                        output = String((output + text).suffix(8_192))
                        if let responder {
                            promptBuffer = String((promptBuffer + text).suffix(1_024))
                            if containsSSHAuthenticationPrompt(promptBuffer) {
                                let prompt = promptBuffer
                                promptBuffer = ""
                                if let response = await responder(prompt) {
                                    channel.write(Array((response + "\n").utf8))
                                }
                            }
                        }
                        let lower = output.lowercased()
                        if SSHFailureClassifier.classify(lower) == .trustDenied {
                            return .denied(output)
                        }
                        if lower.contains("remote forward success for") {
                            return .ready
                        }
                    case let .exited(exitCode):
                        code = exitCode
                    case .failed, .state:
                        continue
                    }
                }
                return .exited(CommandResult(code: code, output: output))
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    return .timeout
                } catch {
                    return .failed("forward setup cancelled")
                }
            }
            let result = await group.next() ?? .timeout
            group.cancelAll()
            return result
        }
    }

    private func forwardEnded(_ endpoint: ForwardedEndpoint) {
        active.removeValue(forKey: endpoint)
        monitors.removeValue(forKey: endpoint)
    }

    private func validate(localSocketPath: String, receiverIssuedName: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard localSocketPath.hasPrefix("/"), !localSocketPath.contains("\0") else {
            throw forwardingError(
                operation: "validate Allward endpoint",
                cause: "local socket path must be absolute and contain no null byte",
                retryability: .nonretryable,
                recovery: "Use the app-owned absolute receiver socket path."
            )
        }

        var socketInfo = stat()
        guard Darwin.lstat(localSocketPath, &socketInfo) == 0,
            socketInfo.st_uid == Darwin.geteuid(),
            socketInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
            socketInfo.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw forwardingError(
                operation: "validate Allward endpoint",
                cause: "local receiver must be an owner-owned mode-0600 UNIX socket",
                retryability: .nonretryable,
                recovery: "Create the app-owned receiver socket before forwarding it."
            )
        }

        guard !receiverIssuedName.isEmpty,
            receiverIssuedName.unicodeScalars.allSatisfy(allowed.contains),
            receiverIssuedName != ".",
            receiverIssuedName != ".."
        else {
            throw forwardingError(
                operation: "validate Allward endpoint",
                cause: "receiver-issued socket name is invalid",
                retryability: .nonretryable,
                recovery: "Issue an opaque filename containing letters, numbers, dot, dash, or underscore."
            )
        }
    }

    private func indicatesMissingControlMaster(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("control socket connect")
            || lower.contains("no controlpath specified")
            || lower.contains("master is not running")
            || lower.contains("no such file or directory")
    }

    private func helperRetryability(_ result: CommandResult) -> AllwardError.Retryability {
        guard result.code == 255 else { return .nonretryable }
        switch SSHFailureClassifier.classifyFinalDiagnostic(result.output) {
        case .trustDenied: return .trustDenied
        case .nonretryable: return .nonretryable
        case .retryable, .none: return .retryable
        }
    }

    private func classify(_ output: String) -> AllwardError.Retryability {
        switch SSHFailureClassifier.classify(output) {
        case .trustDenied: .trustDenied
        case .nonretryable: .nonretryable
        case .retryable, .none: .retryable
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func forwardingError(
        operation: String,
        cause: String,
        retryability: AllwardError.Retryability,
        recovery: String
    ) -> AllwardError {
        AllwardError(
            domain: .transport,
            operation: operation,
            cause: cause,
            retryability: retryability,
            recovery: recovery
        )
    }
}

extension RemoteDestination {
    public func withForwardedEndpoint(_ endpoint: ForwardedEndpoint) -> RemoteDestination {
        var destination = self
        destination.environment["ALLWARD_SOCKET"] = endpoint.remoteSocketPath
        return destination
    }
}
