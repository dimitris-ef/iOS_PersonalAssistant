import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderLocal

/// The shipped catalog, checked as data.
///
/// Every assertion here is about the file `local-models.json`, and each one
/// corresponds to something that would otherwise fail on a user's phone with no
/// useful message: a plain-HTTP URL the transport refuses, a duplicate
/// identifier that makes two entries share one file, a context length nothing
/// can hold.
final class LocalModelCatalogTests: XCTestCase {

    private var catalog: LocalModelCatalog {
        LocalModelCatalog.bundled()
    }

    func testTheShippedCatalogLoads() {
        XCTAssertFalse(
            catalog.models.isEmpty,
            "the bundled catalog failed to load — check Resources are processed for this target"
        )
    }

    /// Section 75. A model file is executable content in every sense that
    /// matters, and the transport refuses plain HTTP — so an entry with one
    /// would be a Download button that always fails.
    func testEveryDownloadURLIsHTTPS() {
        for model in catalog.models {
            guard let url = model.downloadURL else {
                XCTFail("\(model.id) has no download address")
                continue
            }
            XCTAssertEqual(
                url.scheme?.lowercased(),
                "https",
                "\(model.id) would be refused by the transport"
            )
        }
    }

    func testIdentifiersAreUniqueAndPathSafe() {
        var seen: Set<AIModelIdentifier> = []
        var fileNames: Set<String> = []
        for model in catalog.models {
            XCTAssertTrue(seen.insert(model.id).inserted, "duplicate identifier \(model.id)")
            XCTAssertTrue(
                fileNames.insert(model.suggestedFileName).inserted,
                "\(model.id) would share a file with another entry"
            )
            XCTAssertFalse(model.suggestedFileName.contains("/"), "\(model.id) escapes its directory")
            XCTAssertFalse(model.suggestedFileName.contains(".."), "\(model.id) escapes its directory")
        }
    }

    /// Section 5. GGUF is the only format this build can run, so a catalog
    /// entry in another format would be a permanently unavailable row.
    func testEveryShippedModelIsGGUF() {
        for model in catalog.models {
            XCTAssertEqual(model.format, .gguf, "\(model.id) cannot be run by this build")
            XCTAssertTrue(model.isRunnableFormat)
        }
    }

    /// Section 45. A catalog default that is the model's theoretical maximum is
    /// how a 1 GB model becomes a 6 GB allocation.
    func testContextDefaultsAreConservative() {
        for model in catalog.models {
            XCTAssertGreaterThanOrEqual(model.defaultContextLength, 1024, "\(model.id)")
            XCTAssertLessThanOrEqual(
                model.defaultContextLength,
                8192,
                "\(model.id) opens with more context than a phone should"
            )
            if let maximum = model.maximumContextLength {
                XCTAssertLessThanOrEqual(model.defaultContextLength, maximum, "\(model.id)")
            }
        }
    }

    /// Section 7. Every entry has enough metadata for the pre-download checks
    /// to be meaningful.
    func testEveryModelIsDescribedWellEnoughToCheck() {
        for model in catalog.models {
            XCTAssertFalse(model.displayName.isEmpty, "\(model.id)")
            XCTAssertFalse(model.architecture.isEmpty, "\(model.id) cannot be verified after download")
            XCTAssertNotNil(model.fileSizeBytes, "\(model.id) cannot be storage-checked")
            XCTAssertNotNil(model.parameterCount, "\(model.id)")
            XCTAssertNotNil(model.quantization, "\(model.id)")
            XCTAssertNotNil(model.license, "\(model.id) has no recorded licence")
        }
    }

    /// Section 16. An entry the app is not permitted to fetch has to be marked,
    /// not merely hoped about.
    func testEveryShippedModelIsFetchableWithoutCredentials() {
        for model in catalog.models {
            XCTAssertTrue(
                model.license?.isRedistributable == true,
                "\(model.id) is gated — the app has no credential to present"
            )
        }
    }

    /// Section 22. Checksums are optional in the format; a *malformed* one is
    /// not, because it would fail every download with "damaged file".
    func testAnyDeclaredChecksumIsWellFormed() {
        for model in catalog.models {
            guard let checksum = model.checksumSHA256, !checksum.isEmpty else { continue }
            XCTAssertTrue(
                SHA256Hash.isWellFormed(checksum),
                "\(model.id) has a checksum that is not a SHA-256 digest"
            )
        }
    }

    /// Section 131. The set spans small, balanced and larger rather than being
    /// three versions of one thing.
    func testTheCatalogSpansARangeOfSizes() {
        let sizes = catalog.models.compactMap(\.fileSizeBytes).sorted()
        XCTAssertGreaterThanOrEqual(sizes.count, 3, "a curated set of one is a hard-coded model")
        guard let smallest = sizes.first, let largest = sizes.last else { return }
        XCTAssertGreaterThan(
            Double(largest) / Double(smallest),
            2.0,
            "the catalog does not offer a meaningful choice"
        )
    }

    /// Section 15. Nothing may depend on one exact model being present.
    func testAtLeastOneModelSupportsAssistantActions() {
        XCTAssertTrue(catalog.models.contains { $0.toolSupport == .supported })
        XCTAssertGreaterThan(catalog.models.count, 1)
    }

    /// The declared size should be in the same universe as the parameter count
    /// and quantization imply. Catches a copy-paste of the wrong row.
    func testDeclaredSizesAreConsistentWithTheParameterCount() {
        let estimator = LocalModelResourceEstimator.default
        for model in catalog.models {
            guard
                let declared = model.fileSizeBytes,
                let expected = estimator.expectedFileSize(for: model)
            else { continue }
            let ratio = Double(declared) / Double(expected)
            XCTAssertTrue(
                (0.6...1.6).contains(ratio),
                "\(model.id) claims \(declared) bytes; \(model.parameterLabel ?? "?") at "
                    + "\(model.quantization?.rawValue ?? "?") should be nearer \(expected)"
            )
        }
    }

    // MARK: Decoding

    /// The file is edited by hand, so the format has to tolerate an entry that
    /// leaves out everything optional.
    func testAMinimalEntryDecodes() throws {
        let json = """
            {"version":1,"models":[{"id":"tiny","displayName":"Tiny",\
            "architecture":"llama"}]}
            """
        let decoded = try LocalModelCatalog.decode(Data(json.utf8))

        XCTAssertEqual(decoded.models.count, 1)
        let model = try XCTUnwrap(decoded.models.first)
        XCTAssertEqual(model.id, "tiny")
        XCTAssertEqual(model.format, .gguf, "GGUF is the documented default")
        XCTAssertEqual(model.defaultContextLength, 4096)
        XCTAssertEqual(model.toolSupport, .experimental, "unproven until stated otherwise")
        XCTAssertNil(model.checksumSHA256)
    }

    /// The identifier is a bare string in the file, not a wrapper object —
    /// which is the whole reason the descriptor codes itself by hand.
    func testTheCatalogFormatSurvivesARoundTrip() throws {
        let original = catalog.models
        let encoded = try JSONCoding.encoder.encode(
            LocalModelCatalog.CatalogFile(version: 1, models: original)
        )
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("rawValue"), "identifiers must encode as plain strings")

        let decoded = try LocalModelCatalog.decode(encoded)
        XCTAssertEqual(decoded.models, original)
    }

    func testQuantizationIsCasePreservingAndCaseInsensitive() {
        XCTAssertEqual(LocalModelQuantization("q4_k_m"), .q4KM)
        XCTAssertEqual(LocalModelQuantization("Q4_K_M").rawValue, "Q4_K_M")
        XCTAssertTrue(LocalModelQuantization.q4KM.isRecommended)
        // Section 6: an unfamiliar quantization is usable, just not blessed.
        XCTAssertFalse(LocalModelQuantization("IQ1_S").isRecommended)
        XCTAssertNotNil(LocalModelQuantization("IQ1_S").approximateBitsPerWeight)
    }
}
