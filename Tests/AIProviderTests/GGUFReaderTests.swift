import Foundation
import XCTest
@testable import AIProviderLocal

/// Reading a model file's own header, and refusing everything else.
///
/// Section 93 and section 24. The property under test throughout is that a
/// `.gguf` extension proves nothing: what makes a file a model is its magic,
/// its version and a metadata table that parses.
final class GGUFReaderTests: XCTestCase {

    func testAWellFormedHeaderIsRead() throws {
        let header = try GGUFReader.read(GGUFFixture.header())

        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.architecture, "qwen3")
        XCTAssertEqual(header.name, "Test Model")
        XCTAssertEqual(header.tensorCount, 254)
        XCTAssertEqual(header.trainedContextLength, 32768)
        XCTAssertEqual(header.quantization, .q4KM)
    }

    /// The KV figure the memory estimate depends on, derived from the file.
    ///
    /// 2 × 28 blocks × 8 KV heads × 128 key length × 2 bytes = 114,688.
    func testTheKVCacheSizeIsDerivedFromTheHeader() throws {
        let header = try GGUFReader.read(GGUFFixture.header())
        XCTAssertEqual(header.blockCount, 28)
        XCTAssertEqual(header.kvHeadCount, 8)
        // Not recorded by the fixture; derived from embedding_length / head_count.
        XCTAssertEqual(header.keyLength, 2048 / 16)
        XCTAssertEqual(header.kvCacheBytesPerToken, 2 * 28 * 8 * 128 * 2)
    }

    /// No grouped-query metadata means every head has its own KV.
    func testKVHeadsFallBackToTheHeadCount() throws {
        let header = try GGUFReader.read(GGUFFixture.header(kvHeadCount: nil))
        XCTAssertEqual(header.kvHeadCount, 16)
    }

    /// Missing pieces produce nil rather than a number derived from half the
    /// facts — the estimator would rather use its own pessimistic fallback.
    func testAnIncompleteHeaderYieldsNoKVFigure() throws {
        let header = try GGUFReader.read(
            GGUFFixture.header(blockCount: nil, headCount: nil, kvHeadCount: nil, embeddingLength: nil)
        )
        XCTAssertNil(header.kvCacheBytesPerToken)
    }

    func testAChatTemplateIsDetected() throws {
        let without = try GGUFReader.read(GGUFFixture.header())
        let with = try GGUFReader.read(
            GGUFFixture.header(chatTemplate: "{% for m in messages %}{{ m.content }}{% endfor %}")
        )
        XCTAssertFalse(without.hasChatTemplate)
        XCTAssertTrue(with.hasChatTemplate)
    }

    // MARK: Rejection

    /// The case this whole reader exists for: a CDN error page, downloaded to
    /// a file named `model.gguf`.
    func testAnHTMLErrorPageIsNotAModel() {
        XCTAssertThrowsError(try GGUFReader.read(GGUFFixture.notAModel())) { error in
            XCTAssertEqual(error as? GGUFReadError, .notGGUF)
        }
    }

    func testGGUFVersionOneIsRejectedRatherThanMisread() {
        XCTAssertThrowsError(try GGUFReader.read(GGUFFixture.unsupportedVersion())) { error in
            XCTAssertEqual(error as? GGUFReadError, .unsupportedVersion(1))
        }
    }

    /// An interrupted download. The parser must report it, not trap on a short
    /// read — this runs on a phone against a file from the internet.
    func testATruncatedFileIsReportedNotCrashed() {
        XCTAssertThrowsError(try GGUFReader.read(GGUFFixture.truncated()))
    }

    /// A corrupt length field must not become an allocation.
    func testAnImplausibleStringLengthIsRejected() {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: [3, 0, 0, 0]) // version
        data.append(contentsOf: [UInt8](repeating: 0, count: 8)) // tensor count
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0]) // one kv pair
        // A key claiming to be four billion bytes long.
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])

        XCTAssertThrowsError(try GGUFReader.read(data)) { error in
            guard case .malformed = error as? GGUFReadError else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testAnImplausibleMetadataCountIsRejected() {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: [3, 0, 0, 0])
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])

        XCTAssertThrowsError(try GGUFReader.read(data))
    }

    // MARK: From disk

    func testAFileOnDiskIsReadTheSameWay() throws {
        let url = try GGUFFixture.write(GGUFFixture.header(architecture: "llama"))
        defer { try? FileManager.default.removeItem(at: url) }

        let header = try GGUFReader.read(contentsOf: url)
        XCTAssertEqual(header.architecture, "llama")
    }

    func testAMissingFileIsReportedAsUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/model.gguf")
        XCTAssertThrowsError(try GGUFReader.read(contentsOf: url)) { error in
            guard case .unreadable = error as? GGUFReadError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    // MARK: File type mapping

    func testTheCommonQuantizationsAreNamed() {
        XCTAssertEqual(GGUFFileType.quantization(for: 15), .q4KM)
        XCTAssertEqual(GGUFFileType.quantization(for: 17), .q5KM)
        XCTAssertEqual(GGUFFileType.quantization(for: 18), .q6K)
        XCTAssertEqual(GGUFFileType.quantization(for: 7), .q8)
    }

    /// Section 6: llama.cpp adds quantizations faster than this table is
    /// updated, and an unknown one must read as "not recorded" rather than as a
    /// reason to reject a perfectly good file.
    func testAnUnknownFileTypeIsNotAFailure() throws {
        let header = try GGUFReader.read(GGUFFixture.header(fileType: 9_999))
        XCTAssertNil(header.quantization)
        XCTAssertEqual(header.architecture, "qwen3", "the rest of the header still parses")
    }
}
