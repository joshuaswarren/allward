import AllwardControl
import AllwardCore
import Foundation

/// Hosts the app control socket that `allward-mcp` connects to.
///
/// The transport lives here rather than in `AllwardControl` so the control
/// layer stays free of sockets: it only conforms to `ControlRequestHandling`.
/// The descriptor is owner-only and receiver-issued; nothing assumes `/tmp`.
public final class ControlSocketHost: ControlSocketServing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.allward.control-socket")
    private var listener: DispatchSourceRead?
    private var listeningDescriptor: Int32 = -1
    private var socketPath: String?
    private let maximumConnections = 16
    private let maximumLineBytes = 1 << 20

    public init() {}

    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["ALLWARD_APP_SOCKET"],
            !override.isEmpty
        {
            return override
        }
        return AllwardPaths.runtimeDirectory().appendingPathComponent("app.sock").path
    }

    public func start(handler: any ControlRequestHandling, at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.cannotCreateSocket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw ControlSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ControlSocketError.cannotBind(errno)
        }
        chmod(path, 0o600)
        guard listen(descriptor, Int32(maximumConnections)) == 0 else {
            close(descriptor)
            throw ControlSocketError.cannotListen(errno)
        }

        listeningDescriptor = descriptor
        socketPath = path
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(handler: handler) }
        source.resume()
        listener = source
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if listeningDescriptor >= 0 { close(listeningDescriptor) }
        listeningDescriptor = -1
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func accept(handler: any ControlRequestHandling) {
        let client = Foundation.accept(listeningDescriptor, nil, nil)
        guard client >= 0 else { return }
        let connection = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let buffer = LineBuffer(limit: maximumLineBytes)
        connection.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else {
                connection.cancel()
                close(client)
                return
            }
            for line in buffer.append(chunk[0..<count]) {
                self.dispatch(line: line, to: client, handler: handler)
            }
        }
        connection.resume()
    }

    private func dispatch(line: [UInt8], to client: Int32, handler: any ControlRequestHandling) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        guard let request = try? decoder.decode(ControlRequest.self, from: Data(line)) else {
            return
        }
        Task {
            let response = await handler.handle(request)
            guard var payload = try? encoder.encode(response) else { return }
            payload.append(0x0A)
            payload.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, raw.count)
            }
        }
    }
}

public enum ControlSocketError: Error, Sendable {
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
