import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// Which models a person can see.
///
/// Worth testing rather than eyeballing: a filter that silently drops a model
/// the device could run looks identical to a device that cannot run it, and the
/// person concludes their phone is the problem.
final class LocalModelFilteringTests: XCTestCase {

    // MARK: Fixtures

    private func descriptor(
        id: AIModelIdentifier,
        name: String,
        architecture: String,
        parameters: Int64?,
        quantization: LocalModelQuantization = .q4KM,
        summary: String? = nil
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: name,
            architecture: architecture,
            parameterCount: parameters,
            quantization: quantization,
            format: .gguf,
            fileSizeBytes: 1_000_000_000,
            downloadURL: URL(string: "https://example.invalid/\(id).gguf"),
            summary: summary
        )
    }

    private func status(
        _ descriptor: LocalModelDescriptor,
        lifecycle: LocalModelLifecycle = .notDownloaded,
        compatibility: LocalModelCompatibility = .compatible
    ) -> LocalModelStatus {
        LocalModelStatus(
            descriptor: descriptor,
            lifecycle: lifecycle,
            compatibility: compatibility,
            installed: nil,
            isSelected: false
        )
    }

    /// Three families, so a family search has something to exclude.
    private var catalog: [LocalModelStatus] {
        [
            status(
                descriptor(
                    id: "qwen3-1.7b", name: "Qwen3 1.7B",
                    architecture: "qwen3", parameters: 1_700_000_000
                )
            ),
            status(
                descriptor(
                    id: "qwen2-5-3b", name: "Qwen2.5 3B Instruct",
                    architecture: "qwen2", parameters: 3_000_000_000
                ),
                lifecycle: .downloaded
            ),
            status(
                descriptor(
                    id: "smollm2-1.7b", name: "SmolLM2 1.7B Instruct",
                    architecture: "llama", parameters: 1_700_000_000
                ),
                lifecycle: .downloaded
            ),
            status(
                descriptor(
                    id: "gemma-2-2b", name: "Gemma 2 2B Instruct",
                    architecture: "gemma2", parameters: 2_600_000_000
                ),
                compatibility: .likelyTooLarge(reason: "Needs more memory than this device has.")
            ),
        ]
    }

    private func ids(_ statuses: [LocalModelStatus]) -> [String] {
        statuses.map(\.id.rawValue)
    }

    // MARK: Search

    /// Section 59.
    func testSearchingAFamilyNameReturnsOnlyThatFamily() {
        let results = LocalModelSearch.apply(filter: .all, query: "qwen", to: catalog)
        XCTAssertEqual(Set(ids(results)), ["qwen3-1.7b", "qwen2-5-3b"])
    }

    func testSearchIsCaseInsensitive() {
        let lower = LocalModelSearch.apply(filter: .all, query: "smollm", to: catalog)
        let upper = LocalModelSearch.apply(filter: .all, query: "SMOLLM", to: catalog)
        XCTAssertEqual(ids(lower), ids(upper))
        XCTAssertEqual(ids(lower), ["smollm2-1.7b"])
    }

    /// The architecture is what a GGUF calls itself, and somebody debugging a
    /// model will search for it even though it is not in the display name.
    func testSearchMatchesTheArchitecture() {
        let results = LocalModelSearch.apply(filter: .all, query: "gemma2", to: catalog)
        XCTAssertEqual(ids(results), ["gemma-2-2b"])
    }

    /// "1.7B" is how the size is written on screen, so it is how it gets typed.
    func testSearchMatchesTheParameterLabel() {
        let results = LocalModelSearch.apply(filter: .all, query: "1.7B", to: catalog)
        XCTAssertEqual(Set(ids(results)), ["qwen3-1.7b", "smollm2-1.7b"])
    }

    func testSearchMatchesTheQuantization() {
        let results = LocalModelSearch.apply(filter: .all, query: "q4_k_m", to: catalog)
        XCTAssertEqual(results.count, catalog.count)
    }

    func testAnEmptyQueryHidesNothing() {
        XCTAssertEqual(
            LocalModelSearch.apply(filter: .all, query: "", to: catalog).count,
            catalog.count
        )
        XCTAssertEqual(
            LocalModelSearch.apply(filter: .all, query: "   ", to: catalog).count,
            catalog.count
        )
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        XCTAssertTrue(
            LocalModelSearch.apply(filter: .all, query: "mistral", to: catalog).isEmpty
        )
    }

    // MARK: Filters

    func testDownloadedShowsOnlyInstalledModels() {
        let results = LocalModelSearch.apply(filter: .downloaded, query: "", to: catalog)
        XCTAssertEqual(Set(ids(results)), ["qwen2-5-3b", "smollm2-1.7b"])
    }

    func testNotDownloadedIsTheComplement() {
        let downloaded = Set(ids(LocalModelSearch.apply(filter: .downloaded, query: "", to: catalog)))
        let not = Set(ids(LocalModelSearch.apply(filter: .notDownloaded, query: "", to: catalog)))
        XCTAssertTrue(downloaded.isDisjoint(with: not))
        XCTAssertEqual(downloaded.union(not).count, catalog.count)
    }

    /// A model too large for the device is not "compatible", and one already
    /// installed is — even if the catalog would now refuse to download it,
    /// because it is here and it runs.
    func testCompatibleExcludesModelsThisDeviceCannotRun() {
        let results = LocalModelSearch.apply(filter: .compatible, query: "", to: catalog)
        XCTAssertFalse(ids(results).contains("gemma-2-2b"))
        XCTAssertEqual(results.count, 3)
    }

    /// Recommended is a starting point, not a benchmark claim: it means the
    /// quantization is one this app vouches for and the model fits without a
    /// warning.
    func testRecommendedExcludesWarningsAndUnusualQuantizations() {
        let exotic = status(
            descriptor(
                id: "exotic", name: "Exotic 1B", architecture: "llama",
                parameters: 1_000_000_000, quantization: LocalModelQuantization("IQ1_S")
            )
        )
        let warned = status(
            descriptor(id: "warned", name: "Warned 2B", architecture: "llama", parameters: 2_000_000_000),
            compatibility: .compatibleWithWarning(reason: "Tight on memory.")
        )

        let results = LocalModelSearch.apply(
            filter: .recommended, query: "", to: catalog + [exotic, warned]
        )
        let recommended = Set(ids(results))
        XCTAssertFalse(recommended.contains("exotic"))
        XCTAssertFalse(recommended.contains("warned"))
        XCTAssertFalse(recommended.contains("gemma-2-2b"))
        XCTAssertTrue(recommended.contains("qwen3-1.7b"))
    }

    // MARK: They compose

    /// Section 29, and the one most likely to be got wrong: applying only the
    /// filter, or only the query, produces a list that looks right.
    func testFilterAndSearchApplyTogether() {
        let results = LocalModelSearch.apply(filter: .downloaded, query: "qwen", to: catalog)
        XCTAssertEqual(ids(results), ["qwen2-5-3b"])
    }

    func testAFilterAndQueryThatCannotBothMatchReturnsNothing() {
        // Gemma is not downloaded, so this pair is empty rather than falling
        // back to either half.
        XCTAssertTrue(
            LocalModelSearch.apply(filter: .downloaded, query: "gemma", to: catalog).isEmpty
        )
    }

    func testFilteringPreservesTheCatalogOrder() {
        let results = LocalModelSearch.apply(filter: .all, query: "", to: catalog)
        XCTAssertEqual(ids(results), ids(catalog))
    }

    // MARK: The shipped catalog

    /// The catalog is a hand-edited JSON file, so the thing worth asserting is
    /// that it still decodes and still describes runnable models.
    func testTheBundledCatalogDecodesAndSpansSeveralFamilies() {
        let catalog = LocalModelCatalog.bundled()
        XCTAssertGreaterThanOrEqual(
            catalog.models.count, 8,
            "the curated catalog should offer a real choice across size tiers"
        )

        let families = Set(catalog.models.map(\.architecture))
        XCTAssertGreaterThanOrEqual(families.count, 3, "one family is not a choice")

        for model in catalog.models {
            XCTAssertEqual(model.format, .gguf, "\(model.id) is not GGUF and cannot run")
            XCTAssertNotNil(model.downloadURL, "\(model.id) has no download URL")
            XCTAssertEqual(
                model.downloadURL?.scheme, "https",
                "\(model.id) is not fetched over HTTPS"
            )
            XCTAssertNotNil(model.license, "\(model.id) does not say what its licence is")
        }
    }

    /// A catalog spanning one size is not a catalog. The smallest has to fit an
    /// older phone and the largest has to be worth choosing on a new one.
    func testTheCatalogSpansASizeRange() {
        let sizes = LocalModelCatalog.bundled().models.map(\.fileSizeBytes).compactMap { $0 }
        guard let smallest = sizes.min(), let largest = sizes.max() else {
            return XCTFail("the catalog declares no file sizes")
        }
        XCTAssertLessThan(smallest, 700_000_000, "nothing here fits a small device")
        XCTAssertGreaterThan(largest, 2_000_000_000, "nothing here uses a large device")
    }
}
