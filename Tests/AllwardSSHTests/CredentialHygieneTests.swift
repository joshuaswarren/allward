import AllwardCore
import Foundation
import Security
import XCTest

@testable import AllwardSSH

final class CredentialHygieneTests: XCTestCase {
    func testSigningFailureBoundsDiagnosticsWithoutKeyMaterial() throws {
        let fixture = try Self.fixture()
        let algorithm = String(repeating: "!", count: 600)

        XCTAssertThrowsError(try fixture.credential.sign(Data("challenge".utf8), algorithm: algorithm)) { error in
            guard let allward = error as? AllwardError else {
                return XCTFail("expected AllwardError, got \(error)")
            }
            XCTAssertEqual(allward.operation, "sign SSH challenge")
            XCTAssertLessThanOrEqual(allward.cause.count, AllwardError.maximumCauseLength)
            XCTAssertTrue(allward.cause.hasSuffix("…"))
            XCTAssertFalse(allward.cause.contains("-----BEGIN"))
            XCTAssertFalse(allward.cause.contains(fixture.pemBody))
            XCTAssertNil(Data(allward.cause.utf8).range(of: fixture.der))
            XCTAssertNil(Self.base64Run(in: allward.cause))
        }
    }

    func testSignatureBlobContainsAlgorithmAndSignatureButNotPrivateDER() throws {
        let fixture = try Self.fixture()
        let algorithm = "rsa-sha2-256"
        let blob = try fixture.credential.sign(Data("challenge".utf8), algorithm: algorithm)
        var offset = 0
        let encodedAlgorithm = try XCTUnwrap(Self.readSSHString(from: blob, offset: &offset))
        let signature = try XCTUnwrap(Self.readSSHString(from: blob, offset: &offset))

        XCTAssertEqual(String(decoding: encodedAlgorithm, as: UTF8.self), algorithm)
        XCTAssertFalse(signature.isEmpty)
        XCTAssertEqual(offset, blob.count)
        XCTAssertNil(signature.range(of: fixture.der))
        XCTAssertNil(signature.range(of: Data(fixture.der.prefix(32))))
    }

    func testCredentialDescriptionDoesNotContainPrivateMaterial() throws {
        let fixture = try Self.fixture()
        let description = String(describing: fixture.credential)

        XCTAssertFalse(description.contains("-----BEGIN"))
        XCTAssertFalse(description.contains(fixture.pemBody))
        XCTAssertNil(Data(description.utf8).range(of: fixture.der))
    }

    private struct Fixture {
        let credential: SecKeyCredential
        let der: Data
        let pemBody: String
    }

    private static func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["ALLWARD_SSH_TEST_PEM_KEY"] else {
            throw XCTSkip("set ALLWARD_SSH_TEST_PEM_KEY to a PEM RSA private key")
        }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let pemBody = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: pemBody) else {
            throw XCTSkip("\(path) is not a PEM file")
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            der as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            &error
        ) else {
            throw XCTSkip(
                "could not load \(path): "
                    + (error?.takeRetainedValue().localizedDescription ?? "unknown")
            )
        }
        return Fixture(credential: try SecKeyCredential(privateKey: key), der: der, pemBody: pemBody)
    }

    private static func readSSHString(from data: Data, offset: inout Int) -> Data? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        let length = (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
        offset += 4
        guard length >= 0, length <= data.count - offset else { return nil }
        let value = Data(data[offset..<(offset + length)])
        offset += length
        return value
    }

    private static func base64Run(in text: String) -> String? {
        let pattern = #"[A-Za-z0-9+/]{80,}={0,2}"#
        return text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
}
