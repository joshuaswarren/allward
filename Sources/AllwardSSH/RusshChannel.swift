import AllwardCore
import AllwardRemote
import CAllwardSSH
import Foundation

/// One SSH channel, owning a Rust session handle.
///
/// The Rust side calls back from tokio worker threads, so every mutable field is
/// behind one lock and the event stream is the only thing consumers touch. That is
/// also why `context` is an unmanaged pointer to this object: it has to survive
/// until Rust is finished with it, and ARC cannot see across the ABI.
final class RusshChannel: RemoteChannel, @unchecked Sendable {
    let id = ConnectionID()
    let destination: RemoteDestination
    let events: AsyncStream<RemoteEvent>

    private let continuation: AsyncStream<RemoteEvent>.Continuation
    private let hostTrust: any SSHHostTrust
    private let credentials: (any SSHCredentialStore)?
    private let host: HostAlias
    private let lock = NSLock()
    private var session: OpaquePointer?
    /// Retained until Rust stops calling back, then released exactly once.
    private var selfReference: Unmanaged<RusshChannel>?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var settled = false

    private init(
        destination: RemoteDestination,
        host: HostAlias,
        hostTrust: any SSHHostTrust,
        credentials: (any SSHCredentialStore)?
    ) {
        self.destination = destination
        self.host = host
        self.hostTrust = hostTrust
        self.credentials = credentials
        var escaped: AsyncStream<RemoteEvent>.Continuation!
        // Bounded and newest-dropping: a flood must not grow an unbounded queue,
        // and SPEC §21 puts a 2M-line flood inside a second.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { escaped = $0 }
        continuation = escaped
    }

    static func open(
        destination: RemoteDestination,
        host: RemoteHost,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound,
        hostTrust: any SSHHostTrust,
        credentials: (any SSHCredentialStore)?
    ) async throws -> RusshChannel {
        guard let alias = destination.host else {
            throw AllwardError(
                domain: .transport,
                operation: "open SSH session",
                cause: "SSH destination has no host alias",
                retryability: .nonretryable,
                recovery: "Choose a configured SSH host alias."
            )
        }
        let channel = RusshChannel(
            destination: destination, host: alias, hostTrust: hostTrust,
            credentials: credentials)
        try await channel.start(host: host, geometry: geometry, bound: bound)
        return channel
    }

    private func start(
        host configuration: RemoteHost,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound
    ) async throws {
        // NSLock cannot be taken directly in an async function, so every locked
        // field goes through a synchronous accessor.
        let reference = Unmanaged.passRetained(self)
        store(reference: reference)

        let command = destination.command?.joined(separator: " ")
        let callbacks = AllwardSSHCallbacks(
            context: reference.toOpaque(),
            on_state: { context, state in
                RusshChannel.from(context).handle(state: state)
            },
            on_data: { context, bytes, length in
                RusshChannel.from(context).handle(bytes: bytes, length: length)
            },
            on_exit: { context, code, hasCode in
                RusshChannel.from(context).handle(exit: code, hasCode: hasCode)
            },
            on_error: { context, message in
                RusshChannel.from(context).handle(error: message)
            },
            verify_host_key: { context, algorithm, fingerprint, blob, length in
                RusshChannel.from(context).verify(
                    algorithm: algorithm, fingerprint: fingerprint, blob: blob, length: length)
            },
            // Present only when a credential store exists. Null tells Rust to
            // authenticate from the key file instead, which keeps the two paths one
            // decision rather than a runtime branch inside the protocol.
            sign: credentials == nil
                ? nil
                : { context, algorithm, data, length, outSignature, outLength in
                    RusshChannel.from(context).sign(
                        algorithm: algorithm, data: data, length: length,
                        outSignature: outSignature, outLength: outLength)
                }
        )

        let publicKey = credentials?.publicKeyOpenSSH(for: host)

        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            lock.lock()
            readyContinuation = waiter
            lock.unlock()

            let opened = configuration.hostname.withCString { hostname in
                configuration.user.withCString { user in
                    "xterm-256color".withCString { term in
                        withOptionalCString(configuration.identityFile) { keyPath in
                            withOptionalCString(command) { commandPointer in
                                withOptionalCString(publicKey) { publicKeyPointer in
                                    var config = AllwardSSHConfig(
                                        host: hostname,
                                        port: configuration.port,
                                        user: user,
                                        term: term,
                                        columns: UInt32(max(1, geometry.columns)),
                                        rows: UInt32(max(1, geometry.rows)),
                                        command: commandPointer,
                                        want_pty: true,
                                        private_key_path: keyPath,
                                        public_key_openssh: publicKeyPointer,
                                        connect_timeout_ms: UInt64(
                                            max(1, bound.perAttemptTimeout) * 1000)
                                    )
                                    return allward_ssh_open(&config, callbacks)
                                }
                            }
                        }
                    }
                }
            }

            guard let opened else {
                // `on_error` already resumed the waiter with the reason, so there is
                // nothing to add here; releasing the reference is all that remains.
                settle(
                    with: AllwardError(
                        domain: .transport,
                        operation: "open SSH session",
                        cause: "the SSH session could not be created",
                        retryability: .retryable,
                        recovery: "Check the host name and try again."
                    ))
                return
            }
            lock.lock()
            session = opened
            lock.unlock()
        }
    }

    private func store(reference: Unmanaged<RusshChannel>) {
        lock.lock()
        selfReference = reference
        lock.unlock()
    }

    // MARK: - Callbacks from Rust

    private static func from(_ context: UnsafeMutableRawPointer?) -> RusshChannel {
        Unmanaged<RusshChannel>.fromOpaque(context!).takeUnretainedValue()
    }

    private func handle(state: UInt32) {
        switch state {
        case UInt32(ALLWARD_SSH_STATE_CONNECTING):
            continuation.yield(.state(.connecting, nil))
        case UInt32(ALLWARD_SSH_STATE_AUTHENTICATING):
            continuation.yield(.state(.authenticating, nil))
        case UInt32(ALLWARD_SSH_STATE_READY):
            continuation.yield(.state(.ready, nil))
            resumeReady()
        case UInt32(ALLWARD_SSH_STATE_CLOSED):
            continuation.yield(.state(.closed(.explicit), nil))
            continuation.finish()
            release()
        default:
            break
        }
    }

    private func handle(bytes: UnsafePointer<UInt8>?, length: UInt) {
        guard let bytes, length > 0 else { return }
        let buffer = UnsafeBufferPointer(start: bytes, count: Int(length))
        continuation.yield(.bytes(ArraySlice(buffer)))
    }

    private func handle(exit code: Int32, hasCode: Bool) {
        continuation.yield(.exited(code: hasCode ? code : nil))
    }

    private func handle(error message: UnsafePointer<CChar>?) {
        let text = message.map { String(cString: $0) } ?? "an unspecified SSH failure"
        let failure = AllwardError(
            domain: .transport,
            operation: "run SSH session",
            cause: text,
            retryability: .retryable,
            recovery: "Check the host, the network, and the key, then try again."
        )
        continuation.yield(.failed(failure))
        settle(with: failure)
    }

    /// Signs the handshake challenge through the credential store, so the key never
    /// crosses the ABI. The buffer is allocated by Rust's allocator because Rust is
    /// what frees it.
    private func sign(
        algorithm: UnsafePointer<CChar>?,
        data: UnsafePointer<UInt8>?,
        length: UInt,
        outSignature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        outLength: UnsafeMutablePointer<UInt>?
    ) -> Bool {
        guard let credentials, let data, let outSignature, let outLength else { return false }
        let name = algorithm.map { String(cString: $0) } ?? ""
        let payload = Data(UnsafeBufferPointer(start: data, count: Int(length)))
        do {
            let blob = try credentials.sign(payload, algorithm: name, for: host)
            guard let buffer = allward_ssh_allocate(UInt(blob.count)) else { return false }
            blob.withUnsafeBytes { bytes in
                buffer.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: blob.count)
            }
            outSignature.pointee = buffer
            outLength.pointee = UInt(blob.count)
            return true
        } catch {
            continuation.yield(
                .failed(
                    AllwardError(
                        domain: .transport,
                        operation: "sign SSH challenge",
                        cause: "\(error)",
                        retryability: .nonretryable,
                        recovery: "Check the identity configured for \(host.rawValue)."
                    )))
            return false
        }
    }

    /// Rust blocks its handshake on this answer, which is what keeps host trust a
    /// decision Allward makes rather than one the library makes for us.
    private func verify(
        algorithm: UnsafePointer<CChar>?,
        fingerprint: UnsafePointer<CChar>?,
        blob: UnsafePointer<UInt8>?,
        length: UInt
    ) -> Bool {
        let key = SSHHostKey(
            algorithm: algorithm.map { String(cString: $0) } ?? "unknown",
            fingerprint: fingerprint.map { String(cString: $0) } ?? "unknown",
            blob: blob.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
        )
        return hostTrust.accepts(key, for: host)
    }

    // MARK: - RemoteChannel

    func write(_ bytes: [UInt8]) {
        lock.lock()
        let handle = session
        lock.unlock()
        guard let handle else { return }
        _ = bytes.withUnsafeBufferPointer { buffer in
            allward_ssh_write(handle, buffer.baseAddress, UInt(buffer.count))
        }
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        let handle = session
        lock.unlock()
        guard let handle else { return }
        _ = allward_ssh_resize(handle, UInt32(max(1, columns)), UInt32(max(1, rows)))
    }

    func close() {
        lock.lock()
        let handle = session
        lock.unlock()
        guard let handle else { return }
        _ = allward_ssh_close(handle)
    }

    // MARK: - Lifecycle

    private func resumeReady() {
        lock.lock()
        let waiter = readyContinuation
        readyContinuation = nil
        let alreadySettled = settled
        settled = true
        lock.unlock()
        guard !alreadySettled else { return }
        waiter?.resume()
    }

    private func settle(with error: any Error) {
        lock.lock()
        let waiter = readyContinuation
        readyContinuation = nil
        let alreadySettled = settled
        settled = true
        lock.unlock()
        guard !alreadySettled else { return }
        waiter?.resume(throwing: error)
    }

    /// Frees the Rust handle and drops the retain that kept this object alive for
    /// the callbacks. Only the closed state reaches here, so it runs once.
    private func release() {
        lock.lock()
        let handle = session
        session = nil
        let reference = selfReference
        selfReference = nil
        lock.unlock()
        if let handle { allward_ssh_free(handle) }
        reference?.release()
    }
}

/// Calls `body` with a C string, or with nil when there is no value. Nested
/// `withCString` cannot express an optional, and building one by hand leaks.
private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
