import AllwardCore
import Foundation

/// One configured host, as Allward knows it.
///
/// A sandboxed product cannot read `~/.ssh/config`, which
/// docs/evidence/SANDBOX.md measured, so an alias resolves against this and
/// nothing else. That also makes both products resolve hosts identically, which is
/// what the §14 per-target key boundary requires: the stores may differ, the
/// semantics may not.
public struct RemoteHost: Hashable, Sendable {
    public var alias: HostAlias
    public var hostname: String
    public var port: UInt16
    public var user: String
    /// Path to a private key, for the product that authenticates from a file.
    /// The sandboxed product leaves this nil and signs through its credential
    /// store instead, so the transport never requires key bytes.
    public var identityFile: String?

    public init(
        alias: HostAlias,
        hostname: String,
        port: UInt16 = 22,
        user: String,
        identityFile: String? = nil
    ) {
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }
}

/// The live set of configured hosts.
///
/// Configuration reloads while sessions are open, so this is a mutable directory
/// rather than a snapshot passed at construction: a transport built at launch must
/// still see a host added an hour later without being rebuilt.
public final class RemoteHostDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [HostAlias: RemoteHost] = [:]

    public init(_ hosts: [RemoteHost] = []) {
        replace(with: hosts)
    }

    /// Replaces the whole directory. A removed host must stop resolving, so this
    /// is a replacement rather than a merge.
    public func replace(with hosts: [RemoteHost]) {
        lock.lock()
        defer { lock.unlock() }
        self.hosts = Dictionary(hosts.map { ($0.alias, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func host(for alias: HostAlias) -> RemoteHost? {
        lock.lock()
        defer { lock.unlock() }
        return hosts[alias]
    }

    public var aliases: [HostAlias] {
        lock.lock()
        defer { lock.unlock() }
        return hosts.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
