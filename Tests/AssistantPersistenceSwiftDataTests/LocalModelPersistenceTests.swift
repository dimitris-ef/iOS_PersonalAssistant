#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import SwiftData
import XCTest

/// Installed-model records, through the real store and back.
///
/// Section 112: after a relaunch the metadata is still there and the model can
/// be loaded again. What is *not* stored — and the reason this file exists as
/// much as any assertion in it — is the model file itself.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class LocalModelPersistenceTests: PersistenceTestCase {

    private func record(
        id: AIModelIdentifier = "qwen3-1.7b-q4-k-m",
        path: String = "qwen3-1.7b-q4-k-m.gguf"
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: id,
            relativePath: path,
            fileSizeBytes: 1_110_000_000,
            checksumSHA256: String(repeating: "a", count: 64),
            checksumWasDeclared: true,
            installedAt: Self.referenceDate,
            architecture: "qwen3",
            quantization: "Q4_K_M",
            contextLength: 4096
        )
    }

    func testAnInstalledModelSurvivesARelaunch() async throws {
        try await repositories.localModels.save(record())

        try relaunch()

        let reloaded = try await repositories.localModels.model(id: "qwen3-1.7b-q4-k-m")
        let loaded = try XCTUnwrap(reloaded)

        XCTAssertEqual(loaded, record())
        XCTAssertEqual(loaded.relativePath, "qwen3-1.7b-q4-k-m.gguf")
        XCTAssertEqual(loaded.contextLength, 4096)
        XCTAssertTrue(loaded.checksumWasDeclared)
    }

    /// Section 27. Nothing absolute is stored, so a container that moved
    /// between launches cannot orphan the record.
    func testOnlyARelativePathIsStored() async throws {
        try await repositories.localModels.save(record())
        try relaunch()

        let stored = try await repositories.localModels.model(id: "qwen3-1.7b-q4-k-m")
        let loaded = try XCTUnwrap(stored)
        XCTAssertFalse(loaded.relativePath.hasPrefix("/"))
        XCTAssertFalse(loaded.relativePath.contains("Application Support"))
        XCTAssertFalse(loaded.relativePath.contains("/"))
    }

    /// Re-downloading updates the row rather than adding a second one claiming
    /// the same file — two rows would mean deleting one deletes the other's
    /// weights.
    func testReinstallingUpdatesTheSameRow() async throws {
        try await repositories.localModels.save(record())

        var updated = record()
        updated.fileSizeBytes = 1_120_000_000
        updated.lastUsedAt = Self.referenceDate.addingTimeInterval(600)
        try await repositories.localModels.save(updated)

        try relaunch()

        let all = try await repositories.localModels.installedModels()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.fileSizeBytes, 1_120_000_000)
        XCTAssertNotNil(all.first?.lastUsedAt)
    }

    func testDeletingARecordRemovesIt() async throws {
        try await repositories.localModels.save(record())
        try await repositories.localModels.delete(id: "qwen3-1.7b-q4-k-m")

        try relaunch()

        let stored = try await repositories.localModels.model(id: "qwen3-1.7b-q4-k-m")
        XCTAssertNil(stored)
        let all = try await repositories.localModels.installedModels()
        XCTAssertTrue(all.isEmpty)
    }

    func testSeveralModelsCoexistNewestFirst() async throws {
        try await repositories.localModels.save(record(id: "older", path: "older.gguf"))
        var newer = record(id: "newer", path: "newer.gguf")
        newer.installedAt = Self.referenceDate.addingTimeInterval(3600)
        try await repositories.localModels.save(newer)

        try relaunch()

        let all = try await repositories.localModels.installedModels()
        XCTAssertEqual(all.map(\.id), ["newer", "older"])
    }

    /// Section 64. The selection is a setting, and a setting is what survives.
    func testTheSelectedLocalModelSurvivesARelaunch() async throws {
        var settings = try await repositories.settings.settings()
        settings.selectedLocalModelID = "qwen3-1.7b-q4-k-m"
        try await repositories.settings.update(settings)

        try relaunch()

        let reloaded = try await repositories.settings.settings()
        XCTAssertEqual(reloaded.selectedLocalModelID, "qwen3-1.7b-q4-k-m")
    }

    /// A store written before this version has no models and none selected,
    /// which is the truth rather than a default.
    func testAStoreWithNoLocalModelsIsFine() async throws {
        try relaunch()

        let settings = try await repositories.settings.settings()
        XCTAssertNil(settings.selectedLocalModelID)
        let all = try await repositories.localModels.installedModels()
        XCTAssertTrue(all.isEmpty)
    }

    /// Section 26, as an assertion: what the store holds is a description, not
    /// a model. A row is a few hundred bytes whatever the file weighs.
    func testTheRowIsMetadataNotWeights() async throws {
        try await repositories.localModels.save(record())
        let stored = try await repositories.localModels.model(id: "qwen3-1.7b-q4-k-m")
        let loaded = try XCTUnwrap(stored)

        // The record's own encoded size is the check: if weights were ever
        // added to this type, this number would move by nine orders of
        // magnitude and this test would say so.
        let encoded = try JSONCoding.encoder.encode(loaded)
        XCTAssertLessThan(encoded.count, 1024)
        XCTAssertEqual(loaded.fileSizeBytes, 1_110_000_000, "the size is recorded, not occupied")
    }
}

#endif
