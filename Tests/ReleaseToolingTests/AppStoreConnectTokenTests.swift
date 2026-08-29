import Foundation
import XCTest

@testable import ReleaseTooling

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The bearer token the Builds API is queried with.
///
/// ## About keys in these tests
///
/// Section 101, absolutely. Every key here is generated inside the test, exists
/// only in memory, and is thrown away when the test returns. The production
/// `.p8` is never read, never referenced, and cannot be — nothing in this
/// target knows where it lives.
final class AppStoreConnectTokenTests: XCTestCase {

    private let claims = AppStoreConnectToken.Claims(
        issuerID: "00000000-1111-2222-3333-444444444444",
        keyID: "KEYID00000",
        issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    // MARK: Encoding

    func testTheHeaderSaysES256AndNamesTheKey() throws {
        let input = try AppStoreConnectToken.signingInput(for: claims)
        let header = try decodeSegment(input, index: 0)
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        XCTAssertEqual(header["kid"] as? String, "KEYID00000")
    }

    func testTheClaimsAreTheOnesAppleChecks() throws {
        let input = try AppStoreConnectToken.signingInput(for: claims)
        let payload = try decodeSegment(input, index: 1)
        XCTAssertEqual(payload["iss"] as? String, "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["iat"] as? Int, 1_700_000_000)
        XCTAssertEqual(payload["exp"] as? Int, 1_700_000_000 + 900)
    }

    /// Apple refuses a token whose lifetime exceeds twenty minutes, with a bare
    /// 401 that looks exactly like a wrong key.
    func testALifetimeLongerThanApplePermitsIsClamped() throws {
        let greedy = AppStoreConnectToken.Claims(
            issuerID: "issuer",
            keyID: "key",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lifetime: 60 * 60
        )
        XCTAssertEqual(
            greedy.expiresAt.timeIntervalSince(greedy.issuedAt),
            AppStoreConnectToken.Claims.maximumLifetime
        )
    }

    /// Section: base64url, not base64. `+`, `/` and `=` are not legal in a JWS
    /// segment, and the resulting failure is a signature error rather than a
    /// parse error — which sends you looking at the key.
    func testSegmentsAreBase64URLWithoutPadding() throws {
        // Bytes chosen so that plain base64 would certainly contain all three
        // of the characters that must not survive.
        let data = Data([0xFF, 0xEF, 0xBE, 0xFB, 0xEF, 0xFF, 0x00])
        let encoded = AppStoreConnectToken.base64URL(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertTrue(encoded.contains("-") || encoded.contains("_"))
    }

    #if canImport(CryptoKit)

    // MARK: Signing

    func testASignedTokenIsThreeSegmentsAndVerifies() throws {
        let privateKey = P256.Signing.PrivateKey()
        let token = try AppStoreConnectToken.signed(
            claims: claims, key: AppStoreConnectToken.SigningKey(privateKey)
        )

        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)

        let input = segments.dropLast().joined(separator: ".")
        let signature = try XCTUnwrap(base64URLDecode(String(segments[2])))

        // r ‖ s, not DER. Apple accepts only the raw form, and the difference
        // is invisible until the API returns 401.
        XCTAssertEqual(signature.count, 64)

        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(
            privateKey.publicKey.isValidSignature(parsed, for: Data(input.utf8)),
            "the token does not verify against the key that signed it"
        )
    }

    /// The same key round-tripped through the PEM form Apple ships a `.p8` in.
    func testReadsAPrivateKeyInThePEMFormAppleShips() throws {
        let generated = P256.Signing.PrivateKey()
        let key = try AppStoreConnectToken.SigningKey(pem: generated.pemRepresentation)
        let token = try AppStoreConnectToken.signed(claims: claims, key: key)
        XCTAssertEqual(token.split(separator: ".").count, 3)
    }

    /// A malformed key must fail with a sentence that says nothing about what
    /// it read. This is the one error most likely to be looked at while
    /// debugging, and the one most dangerous to make helpful.
    func testAnUnreadableKeyFailsWithoutQuotingIt() {
        XCTAssertThrowsError(
            try AppStoreConnectToken.SigningKey(pem: "-----BEGIN PRIVATE KEY-----\nNOPE\n")
        ) { error in
            let message = "\(error)"
            XCTAssertFalse(message.contains("NOPE"))
            XCTAssertFalse(message.contains("BEGIN PRIVATE KEY"))
            XCTAssertTrue(message.contains("could not be read"))
        }
    }

    #endif

    // MARK: Helpers

    private func decodeSegment(_ token: String, index: Int) throws -> [String: Any] {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        let data = try XCTUnwrap(base64URLDecode(String(segments[index])))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func base64URLDecode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}
