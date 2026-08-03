import AllwardCore
import Foundation
import Security

/// Keys in the Keychain, synchronising over iCloud.
///
/// Decision 39. Apple documents that from macOS 11 the keychain synchronises
/// cryptographic keys and not only passwords, so `kSecAttrSynchronizable` gives a
/// key that follows the user to their other Macs. That costs the `ThisDeviceOnly`
/// protection classes, `SecAccess` control, and persistent references, which is the
/// trade the decision accepted.
///
/// The Secure Enclave is deliberately not used here. It cannot import an existing
/// key and holds only P-256, so none of the keys a user already has can go into it,
/// and a key that cannot leave one enclave cannot appear on another device. It is a
/// separate choice for a freshly generated key, never an upgrade path, and taking
/// it forfeits sync. See docs/evidence/SANDBOX.md.
public final class KeychainCredentialStore: SSHCredentialStore, @unchecked Sendable {
    /// Namespaces items so two Allward builds on one machine cannot read each
    /// other's identities.
    private let service: String
    private let synchronizable: Bool
    private let lock = NSLock()
    private var cache: [HostAlias: SecKeyCredential] = [:]

    public init(service: String = "ai.allward.ssh-identity", synchronizable: Bool = true) {
        self.service = service
        self.synchronizable = synchronizable
    }

    /// Imports a key for a host. The caller supplies a `SecKey`, which is what the
    /// open panel produces after `SecItemImport`, so this never handles raw bytes.
    public func store(privateKey: SecKey, for host: HostAlias) throws {
        let credential = try SecKeyCredential(privateKey: privateKey)
        var attributes = baseQuery(for: host)
        attributes[kSecValueRef as String] = privateKey
        SecItemDelete(baseQuery(for: host) as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.failure(status, "store the identity") }
        lock.lock()
        cache[host] = credential
        lock.unlock()
    }

    public func removeIdentity(for host: HostAlias) throws {
        let status = SecItemDelete(baseQuery(for: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure(status, "remove the identity")
        }
        lock.lock()
        cache[host] = nil
        lock.unlock()
    }

    public func publicKeyOpenSSH(for host: HostAlias) -> String? {
        try? credential(for: host).publicKeyOpenSSH
    }

    public func sign(_ data: Data, algorithm: String, for host: HostAlias) throws -> Data {
        try credential(for: host).sign(data, algorithm: algorithm)
    }

    /// Reads the key once and keeps the `SecKey`, not the key material. A signature
    /// per keystroke would otherwise mean a keychain lookup per keystroke.
    private func credential(for host: HostAlias) throws -> SecKeyCredential {
        lock.lock()
        if let cached = cache[host] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var query = baseQuery(for: host)
        query[kSecReturnRef as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as! SecKey? else {
            throw Self.failure(status, "read the identity for \(host.rawValue)")
        }
        let credential = try SecKeyCredential(privateKey: key)
        lock.lock()
        cache[host] = credential
        lock.unlock()
        return credential
    }

    private func baseQuery(for host: HostAlias) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("\(service).\(host.rawValue)".utf8),
            // A synchronizable item cannot use a `ThisDeviceOnly` protection class,
            // so this is the strongest class compatible with sync.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }

    private static func failure(_ status: OSStatus, _ operation: String) -> AllwardError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return AllwardError(
            domain: .transport,
            operation: operation,
            cause: "\(message) (\(status))",
            retryability: status == errSecInteractionNotAllowed ? .retryable : .nonretryable,
            recovery: status == errSecInteractionNotAllowed
                ? "Unlock the keychain and try again."
                : "Import the key again in Settings."
        )
    }
}
