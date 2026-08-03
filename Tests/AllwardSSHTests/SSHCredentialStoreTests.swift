import AllwardCore
import AllwardRemote
import Foundation
import Security
import XCTest

@testable import AllwardSSH

/// Decision 39 keeps private keys inside Security.framework and has the transport
/// ask for signatures. These prove that path works, which is the part of phase 5
/// that does not need a signing identity: `SecKeyCreateSignature` needs a key, not
/// an entitlement, so the whole external-signer route is verifiable here.
final class SSHCredentialStoreTests: XCTestCase {
    /// SSH wire encoding is small and load-bearing: an off-by-one length makes every
    /// signature invalid with no useful diagnostic.
    func testWireEncodesStringsAndMpints() {
        XCTAssertEqual(Array(SSHWire.string(Data([0x61]))), [0, 0, 0, 1, 0x61])
        XCTAssertEqual(Array(SSHWire.string("")), [0, 0, 0, 0])
        // A high top bit gains a leading zero so it never reads as negative.
        XCTAssertEqual(Array(SSHWire.mpint(Data([0x80]))), [0, 0, 0, 2, 0x00, 0x80])
        // Leading zeros are not significant and come off.
        XCTAssertEqual(Array(SSHWire.mpint(Data([0x00, 0x01]))), [0, 0, 0, 1, 0x01])
        XCTAssertEqual(Array(SSHWire.mpint(Data([0x00]))), [0, 0, 0, 1, 0x00])
    }

    func testSignatureBlobIsAlgorithmThenSignature() {
        let blob = SSHWire.signatureBlob(algorithm: "rsa-sha2-256", signature: Data([0xAA, 0xBB]))
        XCTAssertEqual(
            Array(blob),
            [0, 0, 0, 12] + Array("rsa-sha2-256".utf8) + [0, 0, 0, 2, 0xAA, 0xBB])
    }

    func testDERReadsASequenceOfTwoIntegers() throws {
        // SEQUENCE { INTEGER 0x01, INTEGER 0x0203 }
        let der = Data([0x30, 0x07, 0x02, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03])
        let integers = try DER.sequenceOfIntegers(der)
        XCTAssertEqual(integers.count, 2)
        XCTAssertEqual(Array(integers[0]), [0x01])
        XCTAssertEqual(Array(integers[1]), [0x02, 0x03])
    }

    func testDERRejectsMalformedInput() {
        XCTAssertThrowsError(try DER.sequenceOfIntegers(Data([0x02, 0x01, 0x01])))
        XCTAssertThrowsError(try DER.sequenceOfIntegers(Data([0x30, 0x7F, 0x02])))
    }

    /// An unknown algorithm must be refused. Signing with the wrong digest yields a
    /// signature the server rejects, and guessing turns a clear failure into a
    /// confusing one.
    func testRefusesAnUnknownSignatureAlgorithm() throws {
        let credential = try Self.credentialFromEnvironment()
        XCTAssertThrowsError(try credential.sign(Data("x".utf8), algorithm: "ssh-dss")) { error in
            guard let allward = error as? AllwardError else { return XCTFail("wrong type") }
            XCTAssertTrue(allward.cause.contains("ssh-dss"))
        }
    }

    /// The public line has to match what the server has in `authorized_keys`, or the
    /// server never asks for a signature at all.
    func testDerivesTheOpenSSHPublicLineFromTheKey() throws {
        let credential = try Self.credentialFromEnvironment()
        XCTAssertTrue(credential.publicKeyOpenSSH.hasPrefix("ssh-rsa AAAAB3NzaC1yc2E"))
    }

    /// A signature must be the right size for the key and must be a real blob, not
    /// an empty success.
    func testProducesASignatureBlobForEachRSAAlgorithm() throws {
        let credential = try Self.credentialFromEnvironment()
        for algorithm in ["rsa-sha2-256", "rsa-sha2-512"] {
            let blob = try credential.sign(Data("challenge".utf8), algorithm: algorithm)
            let prefix = SSHWire.string(algorithm)
            XCTAssertTrue(blob.starts(with: prefix), "\(algorithm) blob lacks its algorithm name")
            // 4096-bit key: the signature itself is 512 bytes.
            XCTAssertEqual(blob.count, prefix.count + 4 + 512)
        }
    }

    /// The whole point: a real server accepts a signature Allward produced from a key
    /// it never released. This is the capability `swift-nio-ssh` could not offer.
    func testAuthenticatesToARealServerThroughTheExternalSigner() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ALLWARD_SSH_TEST_HOST"],
            let user = environment["ALLWARD_SSH_TEST_USER"]
        else {
            throw XCTSkip("set ALLWARD_SSH_TEST_HOST and ALLWARD_SSH_TEST_USER")
        }
        let credential = try Self.credentialFromEnvironment()
        let alias = HostAlias("signerHost")
        let store = FixedCredentialStore(credential: credential)
        // No identityFile: the transport must authenticate purely through the signer.
        let directory = RemoteHostDirectory([
            RemoteHost(alias: alias, hostname: host, user: user, identityFile: nil)
        ])
        let transport = RusshTransport(
            hosts: directory, hostTrust: TrustOnFirstUseHostTrust(), credentials: store)
        let channel = try await transport.open(
            .ssh(alias, command: ["echo", "ALLWARD_SIGNER_OK"]),
            geometry: (columns: 80, rows: 24),
            bound: .connect
        )
        var text = ""
        for await event in channel.events {
            if case let .bytes(slice) = event { text += String(decoding: slice, as: UTF8.self) }
            if text.contains("ALLWARD_SIGNER_OK") { break }
            if case let .failed(error) = event { XCTFail("session failed: \(error)"); break }
            if case .exited = event { break }
        }
        channel.close()
        XCTAssertTrue(
            text.contains("ALLWARD_SIGNER_OK"),
            "the server did not accept a signature from the credential store: \(text)")
    }

    /// Loads a PEM RSA key into a `SecKey`. `ALLWARD_SSH_TEST_PEM_KEY` points at a
    /// PEM copy because `SecItemImport` does not read the OpenSSH private format.
    private static func credentialFromEnvironment() throws -> SecKeyCredential {
        guard let path = ProcessInfo.processInfo.environment["ALLWARD_SSH_TEST_PEM_KEY"] else {
            throw XCTSkip("set ALLWARD_SSH_TEST_PEM_KEY to a PEM RSA private key")
        }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64) else {
            throw XCTSkip("\(path) is not a PEM file")
        }
        var error: Unmanaged<CFError>?
        guard
            let key = SecKeyCreateWithData(
                der as CFData,
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ] as CFDictionary,
                &error)
        else {
            throw XCTSkip(
                "could not load \(path): "
                    + (error?.takeRetainedValue().localizedDescription ?? "unknown"))
        }
        return try SecKeyCredential(privateKey: key)
    }
}

/// One identity for every host, which is what a test needs and a product does not.
private struct FixedCredentialStore: SSHCredentialStore {
    let credential: SecKeyCredential

    func publicKeyOpenSSH(for host: HostAlias) -> String? { credential.publicKeyOpenSSH }

    func sign(_ data: Data, algorithm: String, for host: HostAlias) throws -> Data {
        try credential.sign(data, algorithm: algorithm)
    }
}
