import AllwardCore
import Foundation
import Security

/// Keys in the Keychain. Syncing is requested, and currently refused.
///
/// Decision 39. Apple documents that from macOS 11 the keychain synchronises
/// cryptographic keys and not only passwords, so `kSecAttrSynchronizable` should
/// give a key that follows the user to their other Macs, at the cost of the
/// `ThisDeviceOnly` protection classes, `SecAccess` control, and persistent
/// references.
///
/// Measured, that attribute answers `errSecMissingEntitlement` even in a signed
/// sandboxed build: a synchronizable item resolves against access groups that come
/// from an app identifier a provisioning profile supplies, and ours embeds none.
/// Apple documents a single-development-team constraint and never a distribution
/// one, so this is not Mac-App-Store-only as far as the documentation goes. The
/// attribute is set anyway, because it is correct and costs nothing once
/// provisioning exists, but nothing may tell a user their keys sync until a
/// provisioned build proves it. See docs/evidence/SANDBOX.md.
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
    /// A specific keychain to use instead of the default search list.
    ///
    /// This exists so the credential lifecycle can actually be measured. A
    /// non-interactive process cannot touch the login keychain, which answers
    /// `errSecInteractionNotAllowed`, and the data-protection keychain that carries
    /// synchronizable items answers `errSecMissingEntitlement` without a signed
    /// app. Pointing at a keychain the test created is the only way to exercise
    /// import, use, rotation, and deletion against a real Keychain rather than a
    /// double. It is nil in both products.
    ///
    /// A file keychain cannot hold synchronizable items, so passing one turns
    /// syncing off: those runs measure the lifecycle, never iCloud.
    private let keychain: SecKeychain?
    private let lock = NSLock()
    private var cache: [HostAlias: SecKeyCredential] = [:]

    public init(
        service: String = "ai.allward.ssh-identity",
        synchronizable: Bool = true,
        keychain: SecKeychain? = nil
    ) {
        self.service = service
        self.synchronizable = synchronizable && keychain == nil
        self.keychain = keychain
    }

    /// Imports a key for a host. The caller supplies a `SecKey`, which is what the
    /// open panel produces after `SecItemImport`, so this never handles raw bytes.
    public func store(privateKey: SecKey, for host: HostAlias) throws {
        let credential = try SecKeyCredential(privateKey: privateKey)
        var attributes = baseQuery(for: host)
        attributes[kSecValueRef as String] = privateKey
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        // Replacing rather than adding beside: two identities for one host would
        // make which key signs depend on search order.
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
        ]
        if let keychain {
            // Reads and deletes must be scoped too, or they resolve against the
            // default search list and a delete silently misses the item it stored.
            query[kSecMatchSearchList as String] = [keychain] as CFArray
        } else {
            // A synchronizable item cannot use a `ThisDeviceOnly` protection class,
            // so this is the strongest class compatible with sync. It is set only on
            // the data-protection path, since a file keychain rejects both.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
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
