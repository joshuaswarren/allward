import AllwardCore
import Foundation

/// Host trust that survives relaunch.
///
/// Trust on first use is only meaningful if the pin outlives the process: an
/// in-memory store re-trusts a changed key on the next launch, which is the exact
/// attack it is supposed to notice. SPEC §14 assigns host trust to us and lets the
/// two products differ in their store but not in their semantics, so the file path
/// is injected and the decision logic is shared.
///
/// The file lives wherever the caller says. In the sandboxed product that is the
/// container, which docs/evidence/SANDBOX.md measured as the only writable home.
public final class DurableHostTrust: SSHHostTrust, @unchecked Sendable {
    private struct Pin: Codable, Hashable {
        var algorithm: String
        var fingerprint: String
        var firstSeen: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var pins: [String: Pin]
    /// Called when a host presents a key that does not match its pin. This is a
    /// refusal, not a prompt: presenting the mismatch to the user is the app's job,
    /// and a store that asked would make the decision in the wrong place.
    private let onMismatch: @Sendable (HostAlias, SSHHostKey, String) -> Void

    public init(
        url: URL,
        onMismatch: @escaping @Sendable (HostAlias, SSHHostKey, String) -> Void = { _, _, _ in }
    ) {
        self.url = url
        self.onMismatch = onMismatch
        pins = Self.load(from: url)
    }

    /// The store's own path for a product's container.
    public static func defaultURL(inContainer container: URL) -> URL {
        container.appendingPathComponent("known-hosts.json", isDirectory: false)
    }

    public func accepts(_ key: SSHHostKey, for host: HostAlias) -> Bool {
        lock.lock()
        let existing = pins[host.rawValue]
        lock.unlock()

        if let existing {
            guard existing.fingerprint == key.fingerprint else {
                onMismatch(host, key, existing.fingerprint)
                return false
            }
            return true
        }
        lock.lock()
        pins[host.rawValue] = Pin(
            algorithm: key.algorithm, fingerprint: key.fingerprint, firstSeen: Date())
        let snapshot = pins
        lock.unlock()
        Self.save(snapshot, to: url)
        return true
    }

    /// The pinned fingerprint for a host, for the UI that shows it.
    public func pinnedFingerprint(for host: HostAlias) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[host.rawValue]?.fingerprint
    }

    /// Forgets a host so the next connection pins again. This is how a user accepts
    /// a key that legitimately changed, after being shown the mismatch.
    public func forget(_ host: HostAlias) {
        lock.lock()
        pins[host.rawValue] = nil
        let snapshot = pins
        lock.unlock()
        Self.save(snapshot, to: url)
    }

    private static func load(from url: URL) -> [String: Pin] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // A corrupt file must not silently discard every pin, which would re-trust
        // every host. Refusing to read it leaves the file alone and pins nothing, so
        // the next connection is a first use the user sees.
        return (try? JSONDecoder().decode([String: Pin].self, from: data)) ?? [:]
    }

    private static func save(_ pins: [String: Pin], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pins) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a truncated known-hosts file would drop pins, and dropping a pin is
        // how a changed key stops being noticed.
        try? data.write(to: url, options: .atomic)
    }
}
