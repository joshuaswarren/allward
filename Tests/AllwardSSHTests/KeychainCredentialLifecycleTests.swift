import AllwardCore
import Foundation
import Security
import XCTest

@testable import AllwardSSH

/// OQ-14's credential lifecycle: import, use, rotation, and deletion, against a
/// real Keychain rather than a double.
///
/// Each test creates and unlocks its own keychain. That is not a convenience: a
/// non-interactive process cannot touch the login keychain, which answers
/// `errSecInteractionNotAllowed`, and the data-protection keychain that carries
/// synchronizable items answers `errSecMissingEntitlement` without a signed app.
/// A keychain the test made is the only real one reachable here.
///
/// What that leaves unmeasured is stated rather than implied: a file keychain
/// cannot hold synchronizable items, so these runs prove the lifecycle and never
/// iCloud syncing. The sync attribute needs a signed, entitled build.
final class KeychainCredentialLifecycleTests: XCTestCase {
    private var keychainPath: String!
    private var keychain: SecKeychain!

    override func setUpWithError() throws {
        keychainPath = NSTemporaryDirectory() + "allward-oq14-\(UUID().uuidString).keychain-db"
        var created: SecKeychain?
        let status = SecKeychainCreate(keychainPath, 6, "probe-pw", false, nil, &created)
        try XCTSkipIf(
            status != errSecSuccess,
            "could not create a probe keychain: \(status)")
        keychain = created
    }

    override func tearDownWithError() throws {
        if let keychain { SecKeychainDelete(keychain) }
    }

    private func makeStore(service: String = "ai.allward.oq14") -> KeychainCredentialStore {
        KeychainCredentialStore(service: service, synchronizable: true, keychain: keychain)
    }

    /// Generated rather than read from disk: OQ-14 asks for throwaway keys, and a
    /// generated one cannot be confused with anything a person relies on.
    private func makeKey(bits: Int = 2048) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard
            let key = SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeySizeInBits: bits,
                ] as CFDictionary, &error)
        else {
            throw XCTSkip("could not generate a key: \(error!.takeRetainedValue())")
        }
        return key
    }

    /// import, then use. Storing a key is worth nothing if what comes back cannot
    /// sign, which is the only thing the transport asks a credential to do.
    func testImportThenSign() throws {
        let store = makeStore()
        let host = HostAlias("alpha")
        try store.store(privateKey: try makeKey(), for: host)

        let publicKey = store.publicKeyOpenSSH(for: host)
        XCTAssertNotNil(publicKey)
        XCTAssertTrue(publicKey!.hasPrefix("ssh-rsa "))

        let blob = try store.sign(Data("challenge".utf8), algorithm: "rsa-sha2-256", for: host)
        XCTAssertTrue(blob.starts(with: SSHWire.string("rsa-sha2-256")))
        // 2048-bit key: 256 bytes of signature, plus both length-prefixed strings.
        XCTAssertEqual(blob.count, SSHWire.string("rsa-sha2-256").count + 4 + 256)
    }

    /// The stored key must survive a new store instance, or an identity would not
    /// outlive a relaunch and "import" would mean nothing.
    func testAnImportedIdentityIsReadableByANewStore() throws {
        let host = HostAlias("alpha")
        try makeStore().store(privateKey: try makeKey(), for: host)

        let reopened = makeStore()
        XCTAssertNotNil(reopened.publicKeyOpenSSH(for: host))
        XCTAssertNoThrow(
            try reopened.sign(Data("x".utf8), algorithm: "rsa-sha2-256", for: host))
    }

    /// rotation. After replacing a host's identity the new key must sign, and the
    /// old public key must no longer be offered: a rotation that left the old key
    /// reachable would keep authenticating with a key the user retired.
    func testRotationReplacesTheIdentity() throws {
        let store = makeStore()
        let host = HostAlias("alpha")
        try store.store(privateKey: try makeKey(), for: host)
        let first = store.publicKeyOpenSSH(for: host)

        try store.store(privateKey: try makeKey(bits: 3072), for: host)
        let second = store.publicKeyOpenSSH(for: host)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "rotation must change which key is offered")

        // A fresh store reads the keychain rather than a cache, so this proves the
        // replacement reached storage and did not merely update memory.
        XCTAssertEqual(makeStore(service: "ai.allward.oq14").publicKeyOpenSSH(for: host), second)

        let blob = try store.sign(Data("x".utf8), algorithm: "rsa-sha2-256", for: host)
        XCTAssertEqual(blob.count, SSHWire.string("rsa-sha2-256").count + 4 + 384)
    }

    /// deletion. Removing an identity must make signing fail rather than fall back
    /// to anything, and must be visible to a store that reads storage fresh.
    func testDeletionMakesSigningFail() throws {
        let store = makeStore()
        let host = HostAlias("alpha")
        try store.store(privateKey: try makeKey(), for: host)
        XCTAssertNotNil(store.publicKeyOpenSSH(for: host))

        try store.removeIdentity(for: host)

        let reopened = makeStore(service: "ai.allward.oq14")
        XCTAssertNil(reopened.publicKeyOpenSSH(for: host))
        XCTAssertThrowsError(
            try reopened.sign(Data("x".utf8), algorithm: "rsa-sha2-256", for: host))
    }

    /// Deleting something absent is not an error. Rotation deletes before adding, so
    /// a first import would fail if this threw.
    func testDeletingAnAbsentIdentityIsNotAnError() throws {
        XCTAssertNoThrow(try makeStore().removeIdentity(for: HostAlias("never-stored")))
    }

    /// Hosts must not share an identity. One key answering for every host would be a
    /// silent credential leak between machines.
    func testIdentitiesAreScopedPerHost() throws {
        let store = makeStore()
        try store.store(privateKey: try makeKey(), for: HostAlias("alpha"))
        try store.store(privateKey: try makeKey(), for: HostAlias("beta"))

        let alpha = store.publicKeyOpenSSH(for: HostAlias("alpha"))
        let beta = store.publicKeyOpenSSH(for: HostAlias("beta"))
        XCTAssertNotNil(alpha)
        XCTAssertNotEqual(alpha, beta)
        XCTAssertNil(store.publicKeyOpenSSH(for: HostAlias("gamma")))
    }

    /// A different service namespace must not see another's identities, which is what
    /// stops two Allward builds on one machine reading each other's keys.
    func testServiceNamespacesAreIsolated() throws {
        let host = HostAlias("alpha")
        try makeStore(service: "ai.allward.oq14.first").store(privateKey: try makeKey(), for: host)
        XCTAssertNil(makeStore(service: "ai.allward.oq14.second").publicKeyOpenSSH(for: host))
    }
}
