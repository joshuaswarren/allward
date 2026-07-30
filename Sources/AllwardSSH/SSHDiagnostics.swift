import Darwin
import Dispatch
import Foundation

final class SSHDiagnosticLogWatcher: @unchecked Sendable {
    let events: AsyncStream<String>

    private let continuation: AsyncStream<String>.Continuation
    private let fileURL: URL
    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceFileSystemObject
    private let closeLock = NSLock()
    private var closed = false

    // DispatchSource confines file reads to one queue; the lock serialises the one cross-queue close transition.
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = pair.stream
        continuation = pair.continuation
        queue = DispatchQueue(label: "app.allward.ssh.diagnostics.\(UUID().uuidString)")

        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.chmod(fileURL.path, mode_t(0o600)) == 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fileDescriptor = descriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.extend, .write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.resume()
    }

    func finalContents() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }
    func close() {
        let shouldClose = closeLock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        queue.sync {
            source.cancel()
            _ = Darwin.close(fileDescriptor)
            continuation.finish()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func readAvailableBytes() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                continuation.yield(String(decoding: buffer.prefix(count), as: UTF8.self))
            } else if count == -1 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
