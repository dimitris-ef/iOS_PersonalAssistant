import Foundation
import NativeModelKit
import XCTest
@testable import AIProviderLocal

/// The checksum machinery, against published vectors.
///
/// The point of this file: on Apple platforms `SHA256Hash` uses CryptoKit and
/// the portable implementation is dead code — which is exactly how a fallback
/// rots into producing different answers from the real one. So both are exercised
/// here, and on a build that has CryptoKit they are compared against each other
/// as well as against the standard vectors.
final class SHA256Tests: XCTestCase {

    /// FIPS 180-2 / NIST test vectors.
    private let vectors: [(input: String, digest: String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    ]

    func testTheStandardVectors() {
        for vector in vectors {
            XCTAssertEqual(
                SHA256Hash.hexDigest(of: Data(vector.input.utf8)),
                vector.digest,
                "SHA-256 of \"\(vector.input)\""
            )
        }
    }

    func testThePortableImplementationMatchesTheVectors() {
        for vector in vectors {
            var hasher = PortableSHA256()
            hasher.update(Data(vector.input.utf8))
            XCTAssertEqual(hasher.finalizeHex(), vector.digest)
        }
    }

    /// Whichever implementation is compiled, both agree.
    func testBothImplementationsAgreeOnALargerInput() {
        // Deliberately not a round number of 64-byte blocks, so the padding
        // path is what is being checked rather than the happy case.
        let data = Data((0..<100_003).map { UInt8($0 % 251) })

        var portable = PortableSHA256()
        portable.update(data)

        XCTAssertEqual(SHA256Hash.hexDigest(of: data), portable.finalizeHex())
    }

    /// Streaming in chunks is the same as hashing at once — which is what makes
    /// hashing a two-gigabyte file without loading it possible.
    func testChunkedUpdatesMatchASingleUpdate() {
        let data = Data((0..<10_000).map { UInt8($0 % 256) })

        var chunked = PortableSHA256()
        var offset = 0
        for size in [1, 63, 64, 65, 1000, 4096] {
            let end = min(offset + size, data.count)
            guard offset < end else { break }
            chunked.update(data.subdata(in: offset..<end))
            offset = end
        }
        if offset < data.count {
            chunked.update(data.subdata(in: offset..<data.count))
        }

        var whole = PortableSHA256()
        whole.update(data)

        XCTAssertEqual(chunked.finalizeHex(), whole.finalizeHex())
    }

    func testAFileIsHashedFromDisk() throws {
        let payload = GGUFFixture.header()
        let url = try GGUFFixture.write(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try SHA256Hash.hexDigest(ofFileAt: url),
            SHA256Hash.hexDigest(of: payload)
        )
    }

    // MARK: Comparison

    /// Catalogs are written by hand: capital letters and a `sha256:` prefix
    /// both happen, and neither should read as a corrupt download.
    func testComparisonToleratesFormatting() {
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertTrue(SHA256Hash.matches(digest, digest.uppercased()))
        XCTAssertTrue(SHA256Hash.matches("sha256:" + digest, digest))
        XCTAssertTrue(SHA256Hash.matches("  \(digest)\n", digest))
        XCTAssertFalse(SHA256Hash.matches(digest, String(repeating: "0", count: 64)))
    }

    func testWellFormednessIsChecked() {
        XCTAssertTrue(SHA256Hash.isWellFormed(String(repeating: "a", count: 64)))
        XCTAssertFalse(SHA256Hash.isWellFormed(String(repeating: "a", count: 63)))
        XCTAssertFalse(SHA256Hash.isWellFormed(String(repeating: "z", count: 64)))
        XCTAssertFalse(SHA256Hash.isWellFormed(""))
    }
}
