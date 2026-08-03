import AllwardCore
import AllwardRemote
import CAllwardSSH
import Foundation

/// Direct SSH, in process, for both products.
///
/// Decision 40 put russh behind this facade. The protocol runs in `rust/allward-ssh`
/// and reaches Swift through one C ABI; nothing here launches a process, which is
/// what lets `AllwardSSH` link into the sandboxed product at all.
///
/// Host trust and credentials stay on this side. SPEC §14 assigns both to us, and
/// docs/evidence/SANDBOX.md measured why: a sandboxed product cannot read
/// `~/.ssh/known_hosts` or reach ssh-agent, so neither may be assumed.
public struct RusshTransport: RemoteTransport {
    private let hosts: RemoteHostDirectory
    private let hostTrust: any SSHHostTrust
    private let credentials: (any SSHCredentialStore)?

    /// `credentials` signs without releasing the key, which is what the sandboxed
    /// product uses. Absent, the transport authenticates from the host's configured
    /// key file, which is the Developer ID path.
    public init(
        hosts: RemoteHostDirectory,
        hostTrust: any SSHHostTrust = TrustOnFirstUseHostTrust(),
        credentials: (any SSHCredentialStore)? = nil
    ) {
        self.hosts = hosts
        self.hostTrust = hostTrust
        self.credentials = credentials
    }

    public func supports(_ destination: RemoteDestination) -> Bool {
        destination.kind == .ssh && destination.host != nil
    }

    public func open(
        _ destination: RemoteDestination,
        geometry: (columns: Int, rows: Int),
        bound: AttemptBound
    ) async throws -> any RemoteChannel {
        guard let alias = destination.host else {
            throw AllwardError(
                domain: .transport,
                operation: "open SSH session",
                cause: "SSH destination has no host alias",
                retryability: .nonretryable,
                recovery: "Choose a configured SSH host alias."
            )
        }
        guard let host = hosts.host(for: alias) else {
            throw AllwardError(
                domain: .transport,
                operation: "open SSH session",
                cause: "\(alias.rawValue) is not a configured host",
                retryability: .nonretryable,
                recovery: "Add the host to allward.toml. A sandboxed product cannot read "
                    + "~/.ssh/config, so aliases defined there do not resolve."
            )
        }
        return try await RusshChannel.open(
            destination: destination,
            host: host,
            geometry: geometry,
            bound: bound,
            hostTrust: hostTrust,
            credentials: credentials
        )
    }
}

/// What a server offered, for a trust decision.
public struct SSHHostKey: Hashable, Sendable {
    public var algorithm: String
    /// OpenSSH-style `SHA256:...`, which is what a user can compare against.
    public var fingerprint: String
    public var blob: [UInt8]

    public init(algorithm: String, fingerprint: String, blob: [UInt8]) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.blob = blob
    }
}

/// Decides whether to trust a server. Products differ in their store, never in
/// their semantics, which is the §14 per-target key boundary.
public protocol SSHHostTrust: Sendable {
    func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool
}

/// Accepts a host the first time and pins it, then requires a match.
///
/// This is deliberately in-memory. A durable store that survives relaunch, and the
/// mismatch presentation a user actually sees, are phase 5 with OQ-14's fixtures;
/// pinning within a run is the honest subset, and it already refuses a key that
/// changes mid-session.
public final class TrustOnFirstUseHostTrust: SSHHostTrust, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: [HostAlias: String] = [:]

    public init() {}

    public func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let known = pinned[host] { return known == key.fingerprint }
        pinned[host] = key.fingerprint
        return true
    }
}
