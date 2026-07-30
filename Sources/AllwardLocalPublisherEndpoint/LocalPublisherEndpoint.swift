import AllwardCore
import AllwardProtocol
import Darwin
import Foundation

public enum LocalPublisherEndpointError: Error, Equatable, Sendable {
    case runtimeDirectoryUnavailable
    case socketPathTooLong
    case socketCreation(Int32)
    case socketBind(Int32)
    case socketListen(Int32)
    case socketPermissions(Int32)
    case endpointClosed
    case publisherNotConnected
    case writeFailed(Int32)
}

public struct LocalPublisherDescriptor: Codable, Equatable, Sendable {
    public var socketPath: String
    public var key: PublisherTargetKey

    public init(socketPath: String, key: PublisherTargetKey) {
        self.socketPath = socketPath
        self.key = key
    }
}

public struct IncomingDecisionStatus: Equatable, Sendable {
    public var publisher: PublisherID
    public var target: PublisherTargetKey
    public var status: DecisionStatusFrame

    public init(publisher: PublisherID, target: PublisherTargetKey, status: DecisionStatusFrame) {
        self.publisher = publisher
        self.target = target
        self.status = status
    }
}

// Dispatch source callbacks cross concurrency domains; the lock protects every mutable endpoint field.
public final class LocalPublisherEndpoint: @unchecked Sendable {
    public static let maximumConcurrentConnections = 32
    public static let readBufferBytes = 64 * 1024

    public let socketPath: String
    public let publications: AsyncStream<NormalizedPublication>
    public let decisionStatuses: AsyncStream<IncomingDecisionStatus>

    private struct State {
        var listenerFD: Int32
        var listenerSource: DispatchSourceRead?
        var connections: [UUID: Connection] = [:]
        var connectionsByPublisher: [PublisherID: Connection] = [:]
        var closed = false
    }

    private let ledger: GrantLedger
    private let normalizer: PublicationNormalizer
    private let acceptQueue: DispatchQueue
    private let lock = NSLock()
    private var state: State
    private let publicationContinuation: AsyncStream<NormalizedPublication>.Continuation
    private let decisionStatusContinuation: AsyncStream<IncomingDecisionStatus>.Continuation

    public init(
        ledger: GrantLedger,
        normalizer: PublicationNormalizer,
        runtimeDirectory: URL? = nil
    ) throws {
        self.ledger = ledger
        self.normalizer = normalizer
        self.acceptQueue = DispatchQueue(label: "com.allward.publisher.accept", qos: .userInitiated)

        let publicationPair = AsyncStream.makeStream(
            of: NormalizedPublication.self,
            bufferingPolicy: .bufferingNewest(1024)
        )
        self.publications = publicationPair.stream
        self.publicationContinuation = publicationPair.continuation

        let statusPair = AsyncStream.makeStream(
            of: IncomingDecisionStatus.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        self.decisionStatuses = statusPair.stream
        self.decisionStatusContinuation = statusPair.continuation

        let directory = try Self.resolveRuntimeDirectory(explicit: runtimeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw LocalPublisherEndpointError.socketPermissions(errno)
        }

        let path = directory.appendingPathComponent("receiver-\(UUID().uuidString).sock").path
        guard path.utf8.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw LocalPublisherEndpointError.socketPathTooLong
        }

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LocalPublisherEndpointError.socketCreation(errno) }

        do {
            try Self.configureListener(listener)
            try Self.bind(listener, to: path)
            guard chmod(path, mode_t(0o600)) == 0 else {
                throw LocalPublisherEndpointError.socketPermissions(errno)
            }
            guard Darwin.listen(listener, Int32(Self.maximumConcurrentConnections)) == 0 else {
                throw LocalPublisherEndpointError.socketListen(errno)
            }
        } catch {
            Darwin.close(listener)
            Darwin.unlink(path)
            throw error
        }

        self.socketPath = path
        self.state = State(listenerFD: listener)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptReadyConnections()
        }
        lock.lock()
        state.listenerSource = source
        lock.unlock()
        source.resume()
    }

    deinit {
        closeFileDescriptors()
        publicationContinuation.finish()
        decisionStatusContinuation.finish()
    }

    public func issueDescriptor(
        target: Target,
        harness: String,
        publisherName: String,
        credentialGeneration: Generation
    ) async throws -> LocalPublisherDescriptor {
        guard isOpen else { throw LocalPublisherEndpointError.endpointClosed }
        let key = await ledger.mintPublisherTargetKey(
            target: target,
            harness: harness,
            publisherName: publisherName,
            descriptor: UUID().uuidString,
            credentialGeneration: credentialGeneration
        )
        return LocalPublisherDescriptor(socketPath: socketPath, key: key)
    }

    public func send(_ decision: DecisionFrame, to publisher: PublisherID) throws {
        let connection: Connection
        lock.lock()
        let open = !state.closed
        let found = state.connectionsByPublisher[publisher]
        lock.unlock()

        guard open else { throw LocalPublisherEndpointError.endpointClosed }
        guard let found else { throw LocalPublisherEndpointError.publisherNotConnected }
        connection = found
        let data = try FrameEncoder().encode(.decision(decision))
        try connection.send(data)
    }

    public func close() async {
        let publishers = connectedPublishers()

        closeFileDescriptors()
        for publisher in publishers {
            await ledger.markDisconnected(publisher)
        }
        publicationContinuation.finish()
        decisionStatusContinuation.finish()
    }

    private func connectedPublishers() -> [PublisherID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(state.connectionsByPublisher.keys)
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !state.closed
    }

    private func acceptReadyConnections() {
        while true {
            lock.lock()
            let listener = state.listenerFD
            let closed = state.closed
            lock.unlock()
            guard !closed else { return }

            let clientFD = Darwin.accept(listener, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }

            let connection = Connection(fd: clientFD)
            lock.lock()
            if state.closed || state.connections.count >= Self.maximumConcurrentConnections {
                lock.unlock()
                connection.close()
                continue
            }
            state.connections[connection.id] = connection
            lock.unlock()

            Task.detached(priority: .userInitiated) { [weak self, connection] in
                await self?.readConnection(connection)
            }
        }
    }

    private func readConnection(_ connection: Connection) async {
        var decoder = FrameDecoder()
        var granted: GrantedPublisher?
        var receiveBuffer = [UInt8](repeating: 0, count: Self.readBufferBytes)

        connection.configureClient()

        readLoop: while isOpen, connection.isOpen {
            let byteCount = receiveBuffer.withUnsafeMutableBytes { buffer in
                Darwin.recv(connection.fileDescriptor, buffer.baseAddress, buffer.count, 0)
            }
            if byteCount == 0 { break }
            if byteCount < 0 {
                if errno == EINTR { continue }
                break
            }

            let previousIgnored = decoder.ignoredUnknownFrameCount
            let previousRejected = decoder.rejectedBoundCount
            let results = decoder.append(Data(receiveBuffer[0..<byteCount]))
            let ignoredDelta = decoder.ignoredUnknownFrameCount - previousIgnored
            let rejectedDelta = decoder.rejectedBoundCount - previousRejected
            if ignoredDelta > 0 {
                await ledger.noteIgnoredUnknownFrame(count: ignoredDelta)
            }
            if rejectedDelta > 0 {
                await ledger.noteRejectedBound(count: rejectedDelta)
            }

            for result in results {
                switch result {
                case .ignoredUnknownFrame:
                    continue
                case .rejected:
                    break readLoop
                case let .frame(frame):
                    if granted == nil {
                        guard case let .grantRequest(request) = frame else { break readLoop }
                        let response = await ledger.consume(request)
                        do {
                            try connection.send(FrameEncoder().encode(.grantResponse(response)))
                        } catch {
                            break readLoop
                        }
                        guard response.accepted,
                              let accepted = await ledger.activePublisher(for: request.descriptor) else {
                            break readLoop
                        }
                        granted = accepted
                        connection.publisher = accepted.publisher
                        register(connection, for: accepted.publisher)
                        continue
                    }

                    guard let acceptedPublisher = granted else { break readLoop }
                    switch frame {
                    case let .publication(publication):
                        guard await ledger.admits(publication, from: acceptedPublisher.publisher) else {
                            continue
                        }
                        let normalized = await normalizer.accept(publication, from: acceptedPublisher)
                        if case let .accepted(value) = normalized {
                            _ = await ledger.renewLease(
                                for: acceptedPublisher.publisher,
                                epoch: acceptedPublisher.epoch
                            )
                            publicationContinuation.yield(value)
                        }
                    case let .decisionStatus(status):
                        decisionStatusContinuation.yield(
                            IncomingDecisionStatus(
                                publisher: acceptedPublisher.publisher,
                                target: acceptedPublisher.key,
                                status: status
                            )
                        )
                    default:
                        break readLoop
                    }
                }
            }
        }

        unregister(connection)
        connection.close()
        if let publisher = granted?.publisher {
            await ledger.markDisconnected(publisher)
        }
    }

    private func register(_ connection: Connection, for publisher: PublisherID) {
        lock.lock()
        defer { lock.unlock() }
        guard !state.closed else { return }
        state.connectionsByPublisher[publisher] = connection
    }

    private func unregister(_ connection: Connection) {
        lock.lock()
        defer { lock.unlock() }
        state.connections.removeValue(forKey: connection.id)
        if let publisher = connection.publisher,
           state.connectionsByPublisher[publisher]?.id == connection.id {
            state.connectionsByPublisher.removeValue(forKey: publisher)
        }
    }

    private func closeFileDescriptors() {
        let source: DispatchSourceRead?
        let listener: Int32
        let connections: [Connection]

        lock.lock()
        if state.closed {
            lock.unlock()
            return
        }
        state.closed = true
        source = state.listenerSource
        listener = state.listenerFD
        connections = Array(state.connections.values)
        state.listenerSource = nil
        state.connections.removeAll()
        state.connectionsByPublisher.removeAll()
        lock.unlock()

        source?.cancel()
        Darwin.close(listener)
        Darwin.unlink(socketPath)
        for connection in connections {
            connection.close()
        }
    }

    private static func resolveRuntimeDirectory(explicit: URL?) throws -> URL {
        if let explicit {
            guard explicit.path.hasPrefix("/") else {
                throw LocalPublisherEndpointError.runtimeDirectoryUnavailable
            }
            return explicit
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
           xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("Allward", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalPublisherEndpointError.runtimeDirectoryUnavailable
        }
        return applicationSupport
            .appendingPathComponent("Allward", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
    }

    private static func configureListener(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalPublisherEndpointError.socketCreation(errno)
        }
        var noSignal: Int32 = 1
        let optionSize = socklen_t(MemoryLayout.size(ofValue: noSignal))
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, optionSize) == 0 else {
            throw LocalPublisherEndpointError.socketCreation(errno)
        }
    }

    private static func bind(_ fd: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw LocalPublisherEndpointError.socketBind(errno) }
    }
}

// A connection is shared by its read task and receiver send calls; the lock serializes close, identity, and writes.
private final class Connection: @unchecked Sendable {
    let id = UUID()
    let fileDescriptor: Int32

    private let lock = NSLock()
    private var closed = false
    private var publisherID: PublisherID?

    init(fd: Int32) {
        self.fileDescriptor = fd
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    var publisher: PublisherID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return publisherID
        }
        set {
            lock.lock()
            publisherID = newValue
            lock.unlock()
        }
    }

    func configureClient() {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        var noSignal: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
    }

    func send(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw LocalPublisherEndpointError.publisherNotConnected }

        var sent = 0
        let result: Int = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            while sent < buffer.count {
                let count = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), buffer.count - sent, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                sent += count
            }
            return sent
        }
        guard result == data.count else { throw LocalPublisherEndpointError.writeFailed(errno) }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
        lock.unlock()
    }
}
