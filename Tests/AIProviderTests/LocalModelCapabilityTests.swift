import AssistantAI
import AssistantDomain
import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// What a model on this device may be asked to do, and why.
///
/// ## The failure these exist for
///
/// A ~3B model that the catalogue marks action-capable was being treated as
/// chat only on a real phone. Capability lived in exactly one place — a field
/// on the curated catalogue entry — and was read by joining an installed model
/// back to that entry every time somebody looked. Anything the join could not
/// reach had no capability at all.
///
/// The resolver replaces the join with a chain of evidence, so a model without
/// a curated entry still gets an answer, and every answer carries the reason it
/// was reached.
final class LocalModelCapabilityTests: XCTestCase {

    private func descriptor(
        _ id: AIModelIdentifier,
        parameters: Int64,
        toolSupport: LocalModelToolSupport
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: "Test",
            architecture: "qwen2",
            parameterCount: parameters,
            quantization: .q4KM,
            fileSizeBytes: 1_000_000_000,
            downloadURL: URL(string: "https://example.invalid/m.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024,
            toolSupport: toolSupport,
            chatTemplate: .modelDefault
        )
    }

    private func record(
        _ id: AIModelIdentifier = "installed",
        architecture: String?
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: id,
            relativePath: "m.gguf",
            fileSizeBytes: 1_000_000_000,
            installedAt: Date(timeIntervalSince1970: 1_781_078_400),
            architecture: architecture,
            contextLength: 4096
        )
    }

    // MARK: The regression

    /// Section 46. The curated entry is the answer, and the source says so.
    func testACuratedActionCapableModelResolvesToSupported() {
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("qwen2-5-3b", parameters: 3_090_000_000, toolSupport: .supported),
            record: record(architecture: "qwen2")
        )
        XCTAssertEqual(resolution.capability, .supported)
        XCTAssertTrue(resolution.capability.offersTools)
        XCTAssertEqual(resolution.source, .curatedCatalog)
    }

    /// Section 2, the hard requirement, asserted directly: two models identical
    /// but for their size must resolve identically. If anyone ever reaches for
    /// "3B and above can use tools", this fails.
    func testParameterCountAloneChangesNothing() {
        let small = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("m", parameters: 494_000_000, toolSupport: .supported),
            record: record(architecture: "qwen2")
        )
        let large = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("m", parameters: 7_600_000_000, toolSupport: .supported),
            record: record(architecture: "qwen2")
        )
        XCTAssertEqual(small, large)

        // And the converse: a large model the catalogue calls chat-only stays
        // chat-only.
        let largeChatOnly = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("m", parameters: 7_600_000_000, toolSupport: .unsupported),
            record: record(architecture: "gemma2")
        )
        XCTAssertEqual(largeChatOnly.capability, .unsupported)
    }

    /// Section 47. A genuinely chat-only model stays blocked.
    func testAChatOnlyModelStaysChatOnly() {
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("gemma", parameters: 2_600_000_000, toolSupport: .unsupported),
            record: record(architecture: "gemma2")
        )
        XCTAssertEqual(resolution.capability, .unsupported)
        XCTAssertFalse(resolution.capability.offersTools)
    }

    // MARK: Models with no curated entry

    /// Section 7. The case the old catalogue join could not reach at all.
    func testAModelWithNoCatalogEntryFallsBackToItsFamily() {
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: nil, record: record(architecture: "llama")
        )
        // Experimental, not supported: family evidence is weaker than somebody
        // choosing the model deliberately (section 17).
        XCTAssertEqual(resolution.capability, .experimental)
        XCTAssertTrue(resolution.capability.offersTools)
        XCTAssertNotEqual(resolution.source, .curatedCatalog)
    }

    /// A recognised chat template counts before the family does, because it is
    /// evidence about the tool format specifically.
    func testARecognisedTemplateIsItsOwnEvidence() {
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: nil, record: record(architecture: "qwen3")
        )
        XCTAssertEqual(resolution.source, .recognizedChatTemplate)
        XCTAssertEqual(resolution.capability, .experimental)
    }

    /// Section 7 again: unknown is recorded as unknown, not dressed up.
    func testAnUnrecognisedModelIsMarkedUnknownRatherThanClaimed() {
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: nil, record: record(architecture: "some-new-arch")
        )
        XCTAssertEqual(resolution.source, .unknown)
        // Still offered — the tool pipeline's own safeguards stand behind it,
        // and refusing on no evidence would block a capable model for nothing.
        XCTAssertEqual(resolution.capability, .experimental)
    }

    func testAModelWithNoEvidenceAtAllStillResolves() {
        let resolution = LocalModelCapabilityResolver.resolve(descriptor: nil, record: nil)
        XCTAssertEqual(resolution.source, .unknown)
        XCTAssertTrue(resolution.capability.offersTools)
    }

    // MARK: Survival

    /// Sections 8 to 13 as one property. The resolver is a pure function of
    /// persisted evidence, so download, restart, load, unload and selection
    /// cannot change its answer — there is no moment at which the value is
    /// written, and therefore none at which it can be written wrongly.
    func testCapabilityIsStableAcrossEveryLifecycleState() {
        let entry = descriptor("qwen2-5-3b", parameters: 3_090_000_000, toolSupport: .supported)
        let installed = record("qwen2-5-3b", architecture: "qwen2")

        // Freshly downloaded: catalogue entry, record just written.
        let afterDownload = LocalModelCapabilityResolver.resolve(
            descriptor: entry, record: installed
        )
        // After a restart the same two values are read back from disk.
        let afterRestart = LocalModelCapabilityResolver.resolve(
            descriptor: entry, record: installed
        )
        // Loading and unloading are runtime states and touch neither input
        // (section 12).
        var touched = installed
        touched.lastUsedAt = Date(timeIntervalSince1970: 1_781_090_000)
        let afterLoad = LocalModelCapabilityResolver.resolve(
            descriptor: entry, record: touched
        )

        XCTAssertEqual(afterDownload, afterRestart)
        XCTAssertEqual(afterDownload, afterLoad)
        XCTAssertEqual(afterDownload.capability, .supported)
    }

    /// Section 16. A model classified wrongly by an older build is classified
    /// correctly by this one with no migration and no redownload, because
    /// nothing stale was ever stored to be migrated.
    func testAnOldWronglyClassifiedInstallIsCorrectOnFirstRead() {
        // The record is whatever an older build wrote. It carries no capability
        // at all, which is exactly why there is nothing to be stale.
        let resolution = LocalModelCapabilityResolver.resolve(
            descriptor: descriptor("qwen2-5-3b", parameters: 3_090_000_000, toolSupport: .supported),
            record: record("qwen2-5-3b", architecture: "qwen2")
        )
        XCTAssertEqual(resolution.capability, .supported)
    }

    // MARK: The shipped catalogue

    /// Section 6. Guards against the two failure directions at once: the
    /// curated 3B entries must be action-capable, and nothing may be marked
    /// capable merely for being large.
    func testTheShippedCatalogueClassifiesItsThreeBillionModelsAsCapable() throws {
        let catalog = LocalModelCatalog.bundled()
        try XCTSkipIf(catalog.models.isEmpty, "catalog resource unavailable in this runner")

        for id in ["qwen2-5-3b-instruct-q4-k-m", "llama-3-2-3b-instruct-q4-k-m"] {
            let model = try XCTUnwrap(
                catalog.models.first { $0.id.rawValue == id }, "\(id) missing from the catalog"
            )
            XCTAssertTrue(
                model.toolSupport.offersTools,
                "\(id) is intended to support actions and is marked \(model.toolSupport.rawValue)"
            )
        }
    }

    /// Section 6's other half: capability is not a function of size in the
    /// shipped data either. If it were, every model above some threshold would
    /// be capable and every one below it would not.
    func testTheShippedCatalogueIsNotOrderedByParameterCount() throws {
        let catalog = LocalModelCatalog.bundled()
        try XCTSkipIf(catalog.models.isEmpty, "catalog resource unavailable in this runner")

        let capable = catalog.models.filter { $0.toolSupport.offersTools }
        let incapable = catalog.models.filter { !$0.toolSupport.offersTools }
        try XCTSkipIf(capable.isEmpty || incapable.isEmpty, "need both kinds to compare")

        let smallestCapable = capable.compactMap(\.parameterCount).min() ?? 0
        let largestIncapable = incapable.compactMap(\.parameterCount).max() ?? 0
        XCTAssertGreaterThan(
            largestIncapable, smallestCapable,
            "capability tracks size exactly, which would mean it is being decided by size"
        )
    }

    // MARK: Diagnostics

    /// Section 43. Both facts reach the log, and neither is free text.
    func testTheResolutionIsRecordedWithItsReason() {
        let metadata = LocalModelCapabilityResolution(
            capability: .supported, source: .curatedCatalog
        ).metadata()
        XCTAssertEqual(metadata[.toolCapability], .text("supported"))
        XCTAssertEqual(metadata[.capabilitySource], .text("curatedCatalog"))
    }

    func testEverySourceHasSomethingToShow() {
        for source in LocalModelCapabilitySource.allCases {
            XCTAssertFalse(source.label.isEmpty, "\(source.rawValue) has no label")
        }
    }
}
