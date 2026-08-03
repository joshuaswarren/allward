import AllwardCore
import Foundation
import Security

/// Produces SSH signatures without handing anyone the private key.
///
/// Decision 39 keeps keys in the Keychain, so the transport asks for a signature
/// rather than for bytes. That is also why russh was chosen: it accepts an external
/// signer, which `swift-nio-ssh` could not.
public protocol SSHCredentialStore: Sendable {
    /// The public half, in OpenSSH one-line form, for the identity offered to a
    /// host. `nil` means this store has nothing for that host and the transport
    /// should fall back to a configured key file.
    func publicKeyOpenSSH(for host: HostAlias) -> String?

    /// Signs `data` with the private half.
    ///
    /// `algorithm` is the negotiated SSH signature algorithm, which per RFC 8332
    /// determines the digest. The result is a complete SSH signature blob, not raw
    /// signature bytes, because that is what the wire carries.
    func sign(_ data: Data, algorithm: String, for host: HostAlias) throws -> Data
}

/// SSH wire encoding helpers. A signature blob is `string(algorithm)` followed by
/// `string(signature)`, and a `string` is a big-endian length then bytes.
enum SSHWire {
    static func string(_ bytes: Data) -> Data {
        var out = Data()
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }

    static func string(_ text: String) -> Data { string(Data(text.utf8)) }

    /// An SSH `mpint`: two's-complement, big-endian, with a leading zero byte when
    /// the top bit is set so it never reads as negative.
    static func mpint(_ bytes: Data) -> Data {
        var trimmed = Array(bytes.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 { trimmed.insert(0, at: 0) }
        if trimmed.isEmpty { trimmed = [0] }
        return string(Data(trimmed))
    }

    static func signatureBlob(algorithm: String, signature: Data) -> Data {
        string(algorithm) + string(signature)
    }
}

/// A credential backed by a `SecKey`, whether it came from the Keychain, the Secure
/// Enclave, or an imported file.
///
/// The key is only ever used through `SecKeyCreateSignature`, so this works
/// unchanged for a Secure Enclave key that cannot be exported at all.
public struct SecKeyCredential: Sendable {
    private let key: SecKeyBox
    public let publicKeyOpenSSH: String

    public init(privateKey: SecKey) throws {
        key = SecKeyBox(privateKey)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw AllwardError(
                domain: .transport,
                operation: "read SSH identity",
                cause: "the private key has no public half",
                retryability: .nonretryable,
                recovery: "Import the key again."
            )
        }
        publicKeyOpenSSH = try Self.openSSHLine(from: publicKey)
    }

    /// Signs with the digest RFC 8332 ties to `algorithm`.
    ///
    /// An unknown algorithm is refused rather than defaulted: signing with the
    /// wrong digest produces a signature the server rejects, and guessing would
    /// turn a clear failure into a confusing one.
    public func sign(_ data: Data, algorithm: String) throws -> Data {
        let secAlgorithm: SecKeyAlgorithm
        switch algorithm {
        case "rsa-sha2-256":
            secAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case "rsa-sha2-512":
            secAlgorithm = .rsaSignatureMessagePKCS1v15SHA512
        case "ssh-rsa":
            secAlgorithm = .rsaSignatureMessagePKCS1v15SHA1
        case "ecdsa-sha2-nistp256":
            secAlgorithm = .ecdsaSignatureMessageX962SHA256
        default:
            throw AllwardError(
                domain: .transport,
                operation: "sign SSH challenge",
                cause: "unsupported signature algorithm \(algorithm)",
                retryability: .nonretryable,
                recovery: "Use a key whose algorithm the server accepts."
            )
        }
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key.key, secAlgorithm, data as CFData, &error) as Data?
        else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "signing failed"
            throw AllwardError(
                domain: .transport,
                operation: "sign SSH challenge",
                cause: reason,
                retryability: .nonretryable,
                recovery: "Unlock the key and try again."
            )
        }
        return SSHWire.signatureBlob(algorithm: algorithm, signature: signature)
    }

    /// Builds the OpenSSH one-line public key from a `SecKey`.
    ///
    /// RSA's external representation is a PKCS#1 `RSAPublicKey`, which is a DER
    /// SEQUENCE of two INTEGERs: modulus then exponent. SSH wants them in the other
    /// order as `mpint`s, after the algorithm name.
    static func openSSHLine(from publicKey: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw AllwardError(
                domain: .transport,
                operation: "read SSH identity",
                cause: error?.takeRetainedValue().localizedDescription ?? "no representation",
                retryability: .nonretryable,
                recovery: "Import the key again."
            )
        }
        let integers = try DER.sequenceOfIntegers(representation)
        guard integers.count == 2 else {
            throw AllwardError(
                domain: .transport,
                operation: "read SSH identity",
                cause: "expected an RSA public key of two integers, found \(integers.count)",
                retryability: .nonretryable,
                recovery: "Only RSA identities are supported by this path today."
            )
        }
        let blob = SSHWire.string("ssh-rsa") + SSHWire.mpint(integers[1])
            + SSHWire.mpint(integers[0])
        return "ssh-rsa " + blob.base64EncodedString()
    }
}

/// `SecKey` is a CoreFoundation type without a Sendable conformance. It is
/// immutable and thread-safe in use, so the promise is made explicit here instead
/// of spreading `@unchecked` across call sites.
private struct SecKeyBox: @unchecked Sendable {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }
}

/// The minimum DER reader this needs: a SEQUENCE of INTEGERs.
enum DER {
    static func sequenceOfIntegers(_ data: Data) throws -> [Data] {
        var reader = Reader(data)
        let sequence = try reader.expect(tag: 0x30)
        var inner = Reader(sequence)
        var integers: [Data] = []
        while !inner.isAtEnd {
            integers.append(try inner.expect(tag: 0x02))
        }
        return integers
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = Array(data) }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func expect(tag: UInt8) throws -> Data {
            guard offset < bytes.count, bytes[offset] == tag else { throw DERError.malformed }
            offset += 1
            let length = try readLength()
            guard offset + length <= bytes.count else { throw DERError.malformed }
            let value = Data(bytes[offset..<(offset + length)])
            offset += length
            return value
        }

        private mutating func readLength() throws -> Int {
            guard offset < bytes.count else { throw DERError.malformed }
            let first = bytes[offset]
            offset += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 8, offset + count <= bytes.count else {
                throw DERError.malformed
            }
            var length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
            return length
        }
    }

    enum DERError: Error { case malformed }
}
