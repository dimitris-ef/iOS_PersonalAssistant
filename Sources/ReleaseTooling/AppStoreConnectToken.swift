import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// The signed token the App Store Connect API is called with.
///
/// ## Why this exists at all
///
/// `xcrun altool` can upload with an API key, but there is no Apple command
/// line tool that answers "did build 412.2 finish processing, and did it
/// finish *successfully*". That is the Builds resource of the REST API, and the
/// REST API takes a bearer token this code has to mint.
///
/// It matters because an upload succeeding is not the milestone. Apple accepts
/// the transfer, then spends minutes deciding whether the binary is usable, and
/// a build that fails processing is invisible in TestFlight with no email and
/// no signal at the upload site. Part 14, section 73: without this, "uploaded"
/// would be reported as "shipped".
///
/// ## Handling of the key
///
/// The private key arrives as bytes and leaves as a signature. It is never
/// printed, never written anywhere by this type, never included in an error,
/// and never put in a `description`. `SigningKey` is deliberately not
/// `CustomStringConvertible` and holds no copy of the PEM text once parsed.
public struct AppStoreConnectToken {

    /// The claims Apple checks.
    public struct Claims: Equatable, Sendable {
        /// The issuer identifier from App Store Connect → Users and Access →
        /// Integrations. A UUID, not a secret.
        public let issuerID: String
        /// The key identifier. Public in the sense that it names a key rather
        /// than being one — it is literally part of the `.p8` filename Apple
        /// hands you — but still not something to print unnecessarily.
        public let keyID: String
        public let issuedAt: Date
        public let expiresAt: Date

        /// Apple refuses a token whose lifetime exceeds twenty minutes.
        /// Fifteen leaves room for a slow runner clock without ever crossing it.
        public static let maximumLifetime: TimeInterval = 20 * 60
        public static let defaultLifetime: TimeInterval = 15 * 60

        public init(
            issuerID: String,
            keyID: String,
            issuedAt: Date = Date(),
            lifetime: TimeInterval = Claims.defaultLifetime
        ) {
            self.issuerID = issuerID
            self.keyID = keyID
            self.issuedAt = issuedAt
            self.expiresAt = issuedAt.addingTimeInterval(
                min(lifetime, Claims.maximumLifetime)
            )
        }
    }

    /// The unsigned `header.payload` string, ready to be signed.
    ///
    /// Split out from signing so the encoding can be tested without a key at
    /// all — the part most likely to be wrong is the JSON and the base64url,
    /// not the ECDSA.
    public static func signingInput(for claims: Claims) throws -> String {
        let header: [String: String] = [
            "alg": "ES256",
            "kid": claims.keyID,
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": claims.issuerID,
            "iat": Int(claims.issuedAt.timeIntervalSince1970),
            "exp": Int(claims.expiresAt.timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
        ]

        // Sorted keys so the same claims always produce the same bytes. Apple
        // does not care about ordering; a test that compares against a fixture
        // very much does.
        let headerData = try JSONSerialization.data(
            withJSONObject: header, options: [.sortedKeys]
        )
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )

        return base64URL(headerData) + "." + base64URL(payloadData)
    }

    /// base64url per RFC 7515: URL-safe alphabet, no padding.
    ///
    /// Plain base64 would be accepted by nothing — `+` and `/` are not legal in
    /// a JWS segment, and a trailing `=` makes the token fail signature
    /// verification rather than parsing, which is a genuinely confusing failure.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if canImport(CryptoKit)

extension AppStoreConnectToken {

    /// A P-256 private key, held only for as long as it takes to sign.
    public struct SigningKey {
        private let key: P256.Signing.PrivateKey

        /// Reads Apple's `.p8`, which is a PEM-wrapped PKCS#8 P-256 key.
        ///
        /// The error deliberately says nothing about the input. A parse failure
        /// on key material is exactly the situation where a helpful diagnostic
        /// — the first line, the length, a hex prefix — becomes a leak in a log
        /// that is kept for ninety days.
        public init(pem: String) throws {
            do {
                key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            } catch {
                throw AppStoreConnectTokenError.unreadablePrivateKey
            }
        }

        /// Wraps an existing key. Used by tests, which generate their own
        /// ephemeral key and never touch the production one.
        public init(_ key: P256.Signing.PrivateKey) {
            self.key = key
        }

        func signature(over input: String) throws -> Data {
            // `rawRepresentation` is r ‖ s, 64 bytes, which is what JWS ES256
            // specifies. `derRepresentation` is the ASN.1 form and is what a
            // naive implementation reaches for; Apple rejects it with a bare
            // 401 that looks identical to a wrong key.
            try key.signature(for: Data(input.utf8)).rawRepresentation
        }
    }

    /// Mints a bearer token.
    public static func signed(claims: Claims, key: SigningKey) throws -> String {
        let input = try signingInput(for: claims)
        let signature = try key.signature(over: input)
        return input + "." + base64URL(signature)
    }
}

#endif

public enum AppStoreConnectTokenError: Error, Equatable, CustomStringConvertible {
    case unreadablePrivateKey
    case cryptoUnavailable

    public var description: String {
        switch self {
        case .unreadablePrivateKey:
            return "The App Store Connect private key could not be read. Check that the "
                + "secret holds the base64 of the whole .p8 file, including its BEGIN and "
                + "END lines."
        case .cryptoUnavailable:
            return "CryptoKit is unavailable on this platform, so no token can be signed."
        }
    }
}
