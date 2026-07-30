import AllwardCore
import AllwardRemote
import CAllwardPTY
import Darwin
import Dispatch
import Foundation

public struct LocalPTYProcessConfiguration: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var destination: RemoteDestination

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        destination: RemoteDestination
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.destination = destination
    }
}

public struct LocalPTYTransport: RemoteTransport {
    public init() {}

    public func supports(_ destination: RemoteDestination) -> Bool {
        destination.kind == .localShell
    }

    public func open(
        _ destination: RemoteDestination,
        geometry: (columns: Int, rows: Int),
        bound _: AttemptBound
    ) async throws -> any RemoteChannel {
        guard supports(destination) else {
            throw Self.transportError(
                operation: "open local PTY",
                cause: "destination is not a local shell",
                recovery: "Use the SSH transport for SSH destinations."
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(destination.environment) { _, supplied in supplied }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["ALLWARD"] = "1"

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/bin/zsh"
        let loginName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        let configuration = LocalPTYProcessConfiguration(
            executable: shell,
            arguments: [loginName],
            environment: environment,
            workingDirectory: destination.workingDirectory,
            destination: destination
        )
        return try openProcess(configuration, geometry: geometry)
    }

    public func openProcess(
        _ configuration: LocalPTYProcessConfiguration,
        geometry: (columns: Int, rows: Int)
    ) throws -> LocalPTYChannel {
        let spawned = try Self.spawn(configuration, geometry: geometry)
        let wakePipe: (read: Int32, write: Int32)
        do {
            wakePipe = try Self.makeWakePipe()
        } catch {
            _ = Darwin.close(spawned.master)
            _ = Darwin.kill(spawned.child, SIGKILL)
            _ = Darwin.waitpid(spawned.child, nil, 0)
            throw error
        }
        let channel = LocalPTYChannel(
            id: ConnectionID(),
            destination: configuration.destination,
            masterFD: spawned.master,
            childPID: spawned.child,
            wakeReadFD: wakePipe.read,
            wakeWriteFD: wakePipe.write
        )
        channel.start()
        return channel
    }

    private static func spawn(
        _ configuration: LocalPTYProcessConfiguration,
        geometry: (columns: Int, rows: Int)
    ) throws -> (master: Int32, child: pid_t) {
        let strings = [configuration.executable] + configuration.arguments
            + configuration.environment.map { "\($0.key)=\($0.value)" }
            + [configuration.workingDirectory].compactMap { $0 }
        guard strings.allSatisfy({ !$0.contains("\0") }) else {
            throw transportError(
                operation: "spawn PTY",
                cause: "process configuration contains a null byte",
                recovery: "Remove null bytes from the command, environment, or working directory."
            )
        }

        let environmentStrings = configuration.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var argv: [UnsafeMutablePointer<CChar>?] = configuration.arguments.map { strdup($0) }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        argv.append(nil)
        envp.append(nil)
        defer {
            for pointer in argv {
                if let pointer { free(pointer) }
            }
            for pointer in envp {
                if let pointer { free(pointer) }
            }
        }

        var master: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: geometry.rows),
            ws_col: UInt16(clamping: geometry.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let child: pid_t = configuration.executable.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envpBuffer in
                    if let workingDirectory = configuration.workingDirectory {
                        return workingDirectory.withCString { cwd in
                            allward_pty_spawn(
                                &master,
                                &size,
                                executable,
                                argvBuffer.baseAddress,
                                envpBuffer.baseAddress,
                                cwd
                            )
                        }
                    }
                    return allward_pty_spawn(
                        &master,
                        &size,
                        executable,
                        argvBuffer.baseAddress,
                        envpBuffer.baseAddress,
                        nil
                    )
                }
            }
        }
        guard child >= 0 else {
            let failure = String(cString: strerror(errno))
            throw transportError(
                operation: "spawn PTY",
                cause: failure,
                recovery: "Check the executable and working directory, then retry."
            )
        }
        return (master, child)
    }

    private static func makeWakePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            throw transportError(
                operation: "create PTY wake pipe",
                cause: String(cString: strerror(errno)),
                recovery: "Free file descriptors and retry."
            )
        }

        for descriptor in descriptors {
            let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
            let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
            guard statusFlags != -1,
                descriptorFlags != -1,
                Darwin.fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) != -1,
                Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) != -1
            else {
                let failure = String(cString: strerror(errno))
                descriptors.forEach { _ = Darwin.close($0) }
                throw transportError(
                    operation: "configure PTY wake pipe",
                    cause: failure,
                    recovery: "Free file descriptors and retry."
                )
            }
        }
        return (descriptors[0], descriptors[1])
    }

    private static func transportError(
        operation: String,
        cause: String,
        recovery: String
    ) -> AllwardError {
        AllwardError(
            domain: .transport,
            operation: operation,
            cause: cause,
            retryability: .nonretryable,
            recovery: recovery
        )
    }
}

public final class LocalPTYChannel: RemoteChannel, @unchecked Sendable {
    private struct Lifecycle {
        var masterFD: Int32?
        let childPID: pid_t
        var wakeReadFD: Int32?
        var wakeWriteFD: Int32?
        var closing = false
        var readFinished = false
        var childReaped = false
        var exitCode: Int32?
        var streamFinished = false
    }

    public let id: ConnectionID
    public let destination: RemoteDestination
    public let events: AsyncStream<RemoteEvent>

    private let eventBuffer: RemoteEventBuffer
    private let lifecycleLock = NSLock()
    private var lifecycle: Lifecycle
    private let writeQueue: DispatchQueue

    // RemoteChannel has synchronous fd operations; the lock owns lifecycle state and the queue serialises all writes.
    init(
        id: ConnectionID,
        destination: RemoteDestination,
        masterFD: Int32,
        childPID: pid_t,
        wakeReadFD: Int32,
        wakeWriteFD: Int32
    ) {
        self.id = id
        self.destination = destination
        let buffer = RemoteEventBuffer()
        events = buffer.stream
        eventBuffer = buffer
        lifecycle = Lifecycle(
            masterFD: masterFD,
            childPID: childPID,
            wakeReadFD: wakeReadFD,
            wakeWriteFD: wakeWriteFD
        )
        writeQueue = DispatchQueue(label: "app.allward.pty.write.\(id.rawValue.uuidString)")
    }

    deinit {
        close()
    }

    func start() {
        eventBuffer.send(.state(.connecting, nil))
        eventBuffer.send(.state(.ready, nil))

        let reader = Thread { [self] in readLoop() }
        reader.name = "Allward PTY read \(id.shortLabel)"
        reader.qualityOfService = .userInitiated
        reader.start()

        let reaper = Thread { [self] in reapChild() }
        reaper.name = "Allward PTY reap \(id.shortLabel)"
        reaper.qualityOfService = .utility
        reaper.start()
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [self] in
            bytes.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    guard let descriptors = currentWriteDescriptors() else { return }
                    let fd = descriptors.master
                    let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        var polling = [
                            pollfd(fd: fd, events: Int16(POLLOUT), revents: 0),
                            pollfd(fd: descriptors.wake, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                        ]
                        let result = polling.withUnsafeMutableBufferPointer {
                            Darwin.poll($0.baseAddress, 2, -1)
                        }
                        if polling[1].revents != 0 { return }
                        if result <= 0 && errno != EINTR { return }
                    } else {
                        return
                    }
                }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        writeQueue.async { [self] in
            guard let fd = currentWritableFD() else { return }
            var size = winsize(
                ws_row: UInt16(clamping: rows),
                ws_col: UInt16(clamping: columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = Darwin.ioctl(fd, TIOCSWINSZ, &size)
        }
    }

    public func close() {
        let resources = lifecycleLock.withLock { () -> (
            child: pid_t, foreground: pid_t, wake: Int32?
        )? in
            guard !lifecycle.closing && !lifecycle.streamFinished else { return nil }
            lifecycle.closing = true
            lifecycle.streamFinished = true
            let foreground = lifecycle.masterFD.map { Darwin.tcgetpgrp($0) } ?? -1
            eventBuffer.send(.state(.closed(.explicit), nil))
            eventBuffer.finish()
            return (lifecycle.childPID, foreground, lifecycle.wakeWriteFD)
        }
        guard let resources else { return }
        if let wake = resources.wake {
            var byte: UInt8 = 1
            _ = withUnsafeBytes(of: &byte) { Darwin.write(wake, $0.baseAddress, 1) }
        }
        if resources.foreground > 0 && resources.foreground != resources.child {
            terminateProcessGroup(resources.foreground)
        }
        terminateProcessGroup(resources.child)
    }

    private func terminateProcessGroup(_ group: pid_t) {
        if Darwin.kill(-group, SIGKILL) == -1 {
            _ = Darwin.kill(group, SIGKILL)
        }
    }

    private func currentWriteDescriptors() -> (master: Int32, wake: Int32)? {
        lifecycleLock.withLock {
            guard !lifecycle.closing,
                let master = lifecycle.masterFD,
                let wake = lifecycle.wakeReadFD
            else { return nil }
            return (master, wake)
        }
    }

    private func currentWritableFD() -> Int32? {
        lifecycleLock.withLock {
            lifecycle.closing ? nil : lifecycle.masterFD
        }
    }

    private func readLoop() {
        guard let descriptors = lifecycleLock.withLock({ () -> (Int32, Int32)? in
            guard let master = lifecycle.masterFD, let wake = lifecycle.wakeReadFD else { return nil }
            return (master, wake)
        }) else { return }
        let fd = descriptors.0
        let wakeFD = descriptors.1
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var shouldStop = false

        while !shouldStop {
            var polling = [
                pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            ]
            let pollResult = polling.withUnsafeMutableBufferPointer { descriptors in
                Darwin.poll(descriptors.baseAddress, 2, -1)
            }
            if pollResult == -1 && errno == EINTR { continue }
            if pollResult <= 0 { break }
            if polling[1].revents != 0 { break }

            if polling[0].revents & Int16(POLLIN) != 0 {
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if count > 0 {
                    let payload = Array(buffer.prefix(count))
                    eventBuffer.send(.bytes(payload[...]))
                } else if count == 0 {
                    shouldStop = true
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    shouldStop = true
                }
            }

            if polling[0].revents & Int16(POLLHUP | POLLERR) != 0 {
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if count > 0 {
                    let payload = Array(buffer.prefix(count))
                    eventBuffer.send(.bytes(payload[...]))
                } else if count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    shouldStop = true
                } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    shouldStop = true
                }
            }
        }

        retireReadFD(fd, wakeReadFD: wakeFD)
    }

    private func reapChild() {
        let child = lifecycleLock.withLock { lifecycle.childPID }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(child, &status, 0)
        } while result == -1 && errno == EINTR

        let code: Int32? = result == child && (status & 0x7f) == 0
            ? (status >> 8) & 0xff
            : nil
        markChildReaped(code: code)
    }

    private func retireReadFD(_ fd: Int32, wakeReadFD: Int32) {
        let retired = lifecycleLock.withLock { () -> (Int32??, Int32?) in
            if lifecycle.masterFD == fd { lifecycle.masterFD = nil }
            if lifecycle.wakeReadFD == wakeReadFD { lifecycle.wakeReadFD = nil }
            let wakeWriteFD = lifecycle.wakeWriteFD
            lifecycle.wakeWriteFD = nil
            lifecycle.readFinished = true
            return (completionIfReady(), wakeWriteFD)
        }
        writeQueue.sync {
            _ = Darwin.close(fd)
        }
        _ = Darwin.close(wakeReadFD)
        if let wakeWriteFD = retired.1 { _ = Darwin.close(wakeWriteFD) }
        publishCompletion(retired.0)
    }

    private func markChildReaped(code: Int32?) {
        let completion = lifecycleLock.withLock { () -> Int32?? in
            lifecycle.childReaped = true
            lifecycle.exitCode = code
            return completionIfReady()
        }
        publishCompletion(completion)
    }

    private func completionIfReady() -> Int32?? {
        guard lifecycle.readFinished, lifecycle.childReaped, !lifecycle.streamFinished else { return nil }
        lifecycle.streamFinished = true
        return .some(lifecycle.exitCode)
    }

    private func publishCompletion(_ completion: Int32??) {
        guard let completion else { return }
        eventBuffer.send(.exited(code: completion))
        eventBuffer.finish()
    }
}
