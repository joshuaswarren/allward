import AllwardControl
import AllwardCore
import Foundation

/// Hosts the app control socket for the MAS product inside its App Group container.
///
/// Unsandboxed `allward-mcp` connects to this. It is explicitly exempted in the
/// isolation manifest because a sandboxed app may bind a socket inside an app group
/// container it is entitled to, while binding outside remains forbidden.
public final class MASControlSocketHost: ControlSocketServing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.allward.mas-control-socket")
    private var listener: DispatchSourceRead?
    private var listeningDescriptor: Int32 = -1
    private var socketPath: String?
    private let maximumConnections = 16
    private let maximumLineBytes = 1 << 20

    public init() {}

    public func start(handler: any ControlRequestHandling, at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MASControlSocketError.cannotCreateSocket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw MASControlSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { pointer in
            let ptr = pointer.bindMemory(to: UInt8.self).baseAddress!
            for (i, byte) in pathBytes.enumerated() { ptr[i] = byte }
            ptr[pathBytes.count] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else {
            close(descriptor)
            throw MASControlSocketError.cannotBind(errno)
        }

        guard listen(descriptor, Int32(maximumConnections)) == 0 else {
            close(descriptor)
            throw MASControlSocketError.cannotListen(errno)
        }

        self.listeningDescriptor = descriptor
        self.socketPath = path

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(handler: handler) }
        self.listener = source
        source.resume()
    }

    public func stop() {
        queue.sync {
            if let listener {
                listener.cancel()
                self.listener = nil
            }
            if listeningDescriptor >= 0 {
                close(listeningDescriptor)
                listeningDescriptor = -1
            }
            if let path = socketPath {
                try? FileManager.default.removeItem(atPath: path)
                socketPath = nil
            }
        }
    }

    private func accept(handler: any ControlRequestHandling) {
        let client = Foundation.accept(listeningDescriptor, nil, nil)
        guard client >= 0 else { return }

        var value: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let buffer = LineBuffer(limit: maximumLineBytes)

        source.setEventHandler { [weak self] in
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let readBytes = read(client, &readBuffer, readBuffer.count)
            guard readBytes > 0 else {
                source.cancel()
                close(client)
                return
            }
            guard let self else { return }

            for line in buffer.append(readBuffer[..<readBytes]) {
                self.dispatch(line: line, to: client, handler: handler)
            }
        }
        source.resume()
    }

    private func dispatch(line: [UInt8], to client: Int32, handler: any ControlRequestHandling) {
        Task {
            do {
                let request = try JSONDecoder().decode(ControlRequest.self, from: Data(line))
                let response = await handler.handle(request)
                let payload = try JSONEncoder().encode(response)
                Self.sendResponse(payload, to: client)
            } catch {
                Self.sendResponse(Data("{\"error\":\"bad_request\"}\n".utf8), to: client)
            }
        }
    }

    private static func sendResponse(_ payload: Data, to client: Int32) {
        var message = payload
        message.append(0x0A)
        message.withUnsafeBytes { buffer in
            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(client, buffer.baseAddress! + offset, remaining)
                if written > 0 {
                    remaining -= written
                    offset += written
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        var pfd = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                        let pollRes = poll(&pfd, 1, 100)
                        if pollRes <= 0 && (pollRes < 0 && errno != EINTR) {
                            break
                        }
                    } else if err == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }
}

public enum MASControlSocketError: Error, Sendable {
    case cannotCreateSocket(Int32)
    case cannotBind(Int32)
    case cannotListen(Int32)
    case pathTooLong(String)
}

/// Accumulates bytes into newline-delimited frames with a hard bound, so a
/// runaway client cannot make the app allocate without limit.
private final class LineBuffer {
    private var pending: [UInt8] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ bytes: ArraySlice<UInt8>) -> [[UInt8]] {
        pending.append(contentsOf: bytes)
        var lines: [[UInt8]] = []
        while let index = pending.firstIndex(of: 0x0A) {
            lines.append(Array(pending[..<index]))
            pending.removeSubrange(...index)
        }
        if pending.count > limit { pending.removeAll(keepingCapacity: false) }
        return lines
    }
}
