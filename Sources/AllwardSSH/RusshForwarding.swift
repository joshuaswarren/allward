import AllwardCore
import AllwardRemote
import Darwin
import Foundation

public typealias SSHAuthenticationResponder = @Sendable (String) async -> String?

/// A direct-tcpip stream opened through an SSH server.
public final class RusshForwardStream: @unchecked Sendable {
    public let id: UInt64
    public let events: AsyncStream<Data>

    private let channel: RusshChannel
    private let continuation: AsyncStream<Data>.Continuation

    fileprivate init(id: UInt64, channel: RusshChannel) {
        self.id = id
        self.channel = channel
        var escaped: AsyncStream<Data>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { escaped = $0 }
        continuation = escaped
    }

    fileprivate func receive(_ bytes: UnsafePointer<UInt8>?, length: UInt) {
        guard let bytes, length > 0 else { return }
        continuation.yield(Data(bytes: bytes, count: Int(length)))
    }

    fileprivate func finish() {
        continuation.finish()
    }

    public func write(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = channel.forwardWrite(stream: id, bytes: UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    public func close() {
        _ = channel.forwardClose(stream: id)
    }
}

/// Shared endpoint forwarding for Developer ID and MAS.
public actor RusshForwarding {
    private final class UnixSocketBridge: @unchecked Sendable {
        private struct Connection {
            var descriptor: Int32
            var source: DispatchSourceRead
        }

        private let path: String
        private let lock = NSLock()
        private var channel: RusshChannel?
        private var connections: [UInt64: Connection] = [:]

        init(path: String) { self.path = path }

        func attach(_ channel: RusshChannel) {
            lock.lock()
            self.channel = channel
            lock.unlock()
        }

        func open(stream: UInt64) {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                closeRemote(stream)
                return
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8) + [0]
            let copied = withUnsafeMutableBytes(of: &address.sun_path) { storage -> Bool in
                guard pathBytes.count <= storage.count else { return false }
                storage.copyBytes(from: pathBytes)
                return true
            }
            guard copied else {
                Darwin.close(descriptor)
                closeRemote(stream)
                return
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard connected else {
                Darwin.close(descriptor)
                closeRemote(stream)
                return
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
            source.setEventHandler { [weak self] in
                self?.readLocal(stream: stream, descriptor: descriptor)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            lock.lock()
            connections[stream] = Connection(descriptor: descriptor, source: source)
            lock.unlock()
            source.resume()
        }

        func receive(stream: UInt64, bytes: UnsafePointer<UInt8>?, length: UInt) {
            guard let bytes, length > 0 else { return }
            lock.lock()
            let descriptor = connections[stream]?.descriptor
            lock.unlock()
            guard let descriptor else { return }
            var remaining = UnsafeRawBufferPointer(start: bytes, count: Int(length))
            while !remaining.isEmpty {
                let written = Darwin.write(descriptor, remaining.baseAddress!, remaining.count)
                guard written > 0 else {
                    closeRemote(stream)
                    return
                }
                remaining = UnsafeRawBufferPointer(
                    start: remaining.baseAddress!.advanced(by: written),
                    count: remaining.count - written)
            }
        }

        func close(stream: UInt64) {
            lock.lock()
            let connection = connections.removeValue(forKey: stream)
            lock.unlock()
            connection?.source.cancel()
        }

        func closeAll() {
            lock.lock()
            let connections = self.connections
            self.connections.removeAll()
            lock.unlock()
            for connection in connections.values { connection.source.cancel() }
        }

        private func readLocal(stream: UInt64, descriptor: Int32) {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else {
                closeRemote(stream)
                return
            }
            lock.lock()
            let channel = self.channel
            lock.unlock()
            guard let channel else { return }
            _ = bytes.withUnsafeBufferPointer {
                channel.forwardWrite(stream: stream, bytes: UnsafeBufferPointer(start: $0.baseAddress, count: count))
            }
        }

        private func closeRemote(_ stream: UInt64) {
            lock.lock()
            let channel = self.channel
            lock.unlock()
            _ = channel?.forwardClose(stream: stream)
        }
    }

    private struct ActiveForward {
        var channel: RusshChannel
        var bridge: UnixSocketBridge
        var bindHost: String
        var bindPort: UInt16
    }

    private final class StreamBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RusshForwardStream?
        private var pending = Data()
        private var finished = false

        func store(_ stream: RusshForwardStream) {
            lock.lock()
            value = stream
            let buffered = pending
            pending.removeAll(keepingCapacity: false)
            let wasFinished = finished
            lock.unlock()
            if !buffered.isEmpty {
                buffered.withUnsafeBytes { raw in
                    stream.receive(raw.bindMemory(to: UInt8.self).baseAddress, length: UInt(raw.count))
                }
            }
            if wasFinished { stream.finish() }
        }

        func receive(_ bytes: UnsafePointer<UInt8>?, length: UInt) {
            guard let bytes, length > 0 else { return }
            lock.lock()
            if let stream = value {
                lock.unlock()
                stream.receive(bytes, length: length)
            } else {
                pending.append(Data(bytes: bytes, count: Int(length)))
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            guard let stream = value else {
                finished = true
                lock.unlock()
                return
            }
            lock.unlock()
            stream.finish()
        }
    }

    private let hosts: RemoteHostDirectory
    private let hostTrust: any SSHHostTrust
    private let credentials: (any SSHCredentialStore)?
    private var active: [ForwardedEndpoint: ActiveForward] = [:]

    public init(
        hosts: RemoteHostDirectory,
        hostTrust: any SSHHostTrust,
        credentials: (any SSHCredentialStore)? = nil
    ) {
        self.hosts = hosts
        self.hostTrust = hostTrust
        self.credentials = credentials
    }

    public func establish(
        host: HostAlias,
        localSocketPath: String,
        receiverIssuedName: String,
        bound: AttemptBound = .connect
    ) async throws -> ForwardedEndpoint {
        try validate(localSocketPath: localSocketPath, receiverIssuedName: receiverIssuedName)
        guard let configuration = hosts.host(for: host) else {
            throw failure("forward Allward endpoint", "host \(host.rawValue) is not configured")
        }
        let bridge = UnixSocketBridge(path: localSocketPath)
        let channel = try await RusshChannel.open(
            destination: .ssh(host), host: configuration, geometry: (1, 1), bound: bound,
            hostTrust: hostTrust, credentials: credentials,
            forwardOpen: { stream, _, _ in bridge.open(stream: stream) },
            forwardData: { stream, bytes, length in bridge.receive(stream: stream, bytes: bytes, length: length) },
            forwardClose: { stream in bridge.close(stream: stream) })
        bridge.attach(channel)

        let seed = receiverIssuedName.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        for offset in 0..<64 {
            let candidate = UInt16(40_000 + Int((seed + UInt32(offset)) % 20_000))
            guard channel.forwardRemoteOpen(host: "127.0.0.1", port: candidate) else { continue }
            let endpoint = ForwardedEndpoint(
                remoteSocketPath: "127.0.0.1:\(candidate)",
                localSocketPath: localSocketPath,
                host: host)
            active[endpoint] = ActiveForward(
                channel: channel, bridge: bridge, bindHost: "127.0.0.1", bindPort: candidate)
            return endpoint
        }
        channel.close()
        throw failure(
            "forward Allward endpoint",
            "the remote host refused every candidate loopback port",
            recovery: "Check the SSH forwarding policy and retry.")
    }

    public func close(_ endpoint: ForwardedEndpoint, bound _: AttemptBound = .controlRequest) async throws {
        guard let forward = active.removeValue(forKey: endpoint) else { return }
        guard forward.channel.forwardRemoteClose(host: forward.bindHost, port: forward.bindPort) else {
            forward.bridge.closeAll()
            forward.channel.close()
            throw failure(
                "cancel Allward endpoint forward",
                "the remote host refused the forwarding cancellation",
                recovery: "Check the SSH forwarding policy.")
        }
        forward.bridge.closeAll()
        forward.channel.close()
    }

    public func openLocal(
        host alias: HostAlias,
        targetHost: String,
        targetPort: UInt16,
        bound: AttemptBound = .connect
    ) async throws -> RusshForwardStream {
        guard let configuration = hosts.host(for: alias) else {
            throw failure("open direct-tcpip stream", "host \(alias.rawValue) is not configured")
        }
        let box = StreamBox()
        let channel = try await RusshChannel.open(
            destination: .ssh(alias), host: configuration, geometry: (1, 1), bound: bound,
            hostTrust: hostTrust, credentials: credentials,
            forwardOpen: { _, _, _ in },
            forwardData: { _, bytes, length in box.receive(bytes, length: length) },
            forwardClose: { _ in box.finish() })
        let id = channel.forwardLocalOpen(host: targetHost, port: targetPort)
        guard id != 0 else {
            channel.close()
            throw failure("open direct-tcpip stream", "the SSH server refused the target channel")
        }
        let result = RusshForwardStream(id: id, channel: channel)
        box.store(result)
        return result
    }

    public func withForwardedEndpoint(_ endpoint: ForwardedEndpoint) -> RemoteDestination {
        .ssh(endpoint.host, command: nil, environment: ["ALLWARD_SOCKET": endpoint.remoteSocketPath])
    }

    private func validate(localSocketPath: String, receiverIssuedName: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard localSocketPath.hasPrefix("/"), !localSocketPath.contains("\0") else {
            throw failure("validate Allward endpoint", "local receiver must be an absolute socket path")
        }
        var info = stat()
        guard Darwin.lstat(localSocketPath, &info) == 0,
            info.st_uid == Darwin.geteuid(),
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
            info.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw failure(
                "validate Allward endpoint",
                "local receiver must be an owner-owned mode-0600 UNIX socket",
                recovery: "Create the app-owned receiver socket before forwarding it.")
        }
        guard !receiverIssuedName.isEmpty,
            receiverIssuedName.unicodeScalars.allSatisfy(allowed.contains),
            receiverIssuedName != ".", receiverIssuedName != ".."
        else {
            throw failure("validate Allward endpoint", "receiver-issued socket name is invalid")
        }
    }

    private func failure(
        _ operation: String,
        _ cause: String,
        recovery: String = "Check the SSH host and retry."
    ) -> AllwardError {
        AllwardError(
            domain: .transport, operation: operation, cause: cause,
            retryability: .retryable, recovery: recovery)
    }
}

public extension RemoteDestination {
    func withForwardedEndpoint(_ endpoint: ForwardedEndpoint) -> RemoteDestination {
        var destination = self
        destination.environment["ALLWARD_SOCKET"] = endpoint.remoteSocketPath
        return destination
    }
}
