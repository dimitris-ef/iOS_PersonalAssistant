import Foundation
import NativeModelKit
import SpeechToText
import XCTest

@testable import SpeechToTextLocal

/// The on-device speech model system: download, verification, compatibility and
/// deletion, none of which needs a 142 MB file or a GPU.
final class LocalSpeechModelTests: XCTestCase {

    // MARK: Harness

    /// A transport that produces bytes a test chose.
    private actor StubTransport: ModelDownloadTransport {
        enum Behaviour: Sendable {
            case delivers(Data)
            case fails(NativeDownloadError)
        }

        private var behaviour: Behaviour
        private(set) var downloadCount = 0
        private(set) var cancelCount = 0
        private(set) var requestedURLs: [URL] = []

        init(behaviour: Behaviour) { self.behaviour = behaviour }

        func download(
            from url: URL,
            resumeData: Data?,
            onProgress: @Sendable @escaping (NativeDownloadProgress) -> Void
        ) async throws -> DownloadedFile {
            downloadCount += 1
            requestedURLs.append(url)
            switch behaviour {
            case .delivers(let payload):
                // Progress arrives the way a real transfer reports it.
                onProgress(NativeDownloadProgress(
                    bytesReceived: Int64(payload.count / 2),
                    bytesExpected: Int64(payload.count)
                ))
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speech-\(UUID().uuidString).part")
                try payload.write(to: file)
                return DownloadedFile(url: file, byteCount: Int64(payload.count))
            case .fails(let error):
                throw error
            }
        }

        func cancel(url: URL) async -> Data? {
            cancelCount += 1
            return nil
        }

        func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }
    }

    /// A well-formed ggml file of a chosen size.
    ///
    /// Real Whisper weights start with the `ggml` magic; everything after it is
    /// opaque to the checks under test, so padding is enough.
    private func ggmlPayload(bytes: Int) -> Data {
        var data = Data(Array("ggml".utf8))
        data.append(Data(repeating: 0x42, count: max(0, bytes - 4)))
        return data
    }

    private func model(
        id: SpeechModelIdentifier = "test-base",
        size: Int64 = 1024,
        checksum: String? = nil,
        englishOnly: Bool = true,
        variant: WhisperModelVariant = .base
    ) -> LocalSpeechModelDescriptor {
        LocalSpeechModelDescriptor(
            id: id,
            displayName: "Test Base",
            summary: "For tests.",
            variant: variant,
            quantization: .q5_1,
            isEnglishOnly: englishOnly,
            fileSize: size,
            checksum: checksum,
            downloadURL: URL(string: "https://example.invalid/ggml-base.en.bin"),
            fileName: "ggml-test-base.bin"
        )
    }

    private func makeManager(
        catalog: [LocalSpeechModelDescriptor],
        transport: StubTransport,
        runtime: any LocalSpeechRuntime = MockLocalSpeechRuntime(),
        device: any DeviceResourceProvider = FixedDeviceResources.midPhone,
        selected: SpeechModelIdentifier? = nil
    ) -> (LocalSpeechModelManager, NativeFileStore) {
        let store = NativeFileStore.temporary(prefix: "speech-test")
        let manager = LocalSpeechModelManager(
            catalog: catalog,
            store: store,
            downloads: NativeDownloadManager(transport: transport),
            device: device,
            runtime: runtime,
            selected: selected
        )
        return (manager, store)
    }

    // MARK: Download

    /// Section 105. Download, progress, verification, install — and the model
    /// becomes selectable.
    func testASuccessfulDownloadInstallsAndBecomesSelectable() async throws {
        let descriptor = model(size: 4096)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        var reported: [NativeProgressSnapshot] = []
        let installed = try await manager.download(descriptor.id) { reported.append($0) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertEqual(lifecycle, .downloaded)
        XCTAssertTrue(lifecycle.isInstalled)

        // Section 31: bytes and a percentage, not just a spinner.
        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported.last?.fractionComplete, 1)
        XCTAssertTrue(reported.last?.label.contains("100%") ?? false)

        // The first model downloaded becomes the selection, so the user does
        // not have to make a second choice to use what they just fetched.
        let selected = await manager.selectedModel()
        XCTAssertEqual(selected, descriptor.id)
    }

    /// Section 106. A wrong checksum rejects the model, removes the file and
    /// leaves it retryable.
    func testACorruptDownloadIsRejectedAndTheFileRemoved() async throws {
        let descriptor = model(
            size: 4096,
            checksum: String(repeating: "a", count: 64)   // will not match
        )
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        do {
            _ = try await manager.download(descriptor.id)
            XCTFail("a model with a wrong checksum was installed")
        } catch let error as SpeechToTextError {
            guard case .modelCorrupt = error else {
                return XCTFail("expected modelCorrupt, got \(error)")
            }
        }

        // Section 33: nothing installed, nothing left on disk.
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertFalse(lifecycle.isInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.url(forRelativePath: descriptor.fileName).path
            )
        )
    }

    /// Section 26. A file whose name looks right and whose contents are an HTML
    /// error page is not a model.
    func testAnErrorPageIsNotAcceptedAsAModel() async throws {
        let descriptor = model(size: 60)
        let html = Data("<!DOCTYPE html><html><body>404</body></html>".utf8)
        let transport = StubTransport(behaviour: .delivers(html))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        do {
            _ = try await manager.download(descriptor.id)
            XCTFail("an HTML page was installed as a speech model")
        } catch let error as SpeechToTextError {
            guard case .modelCorrupt = error else {
                return XCTFail("expected modelCorrupt, got \(error)")
            }
        }
    }

    /// A truncated transfer is caught by the size check even with no published
    /// checksum — the case the catalog's missing digests would otherwise leave
    /// unguarded.
    func testATruncatedDownloadIsRejectedWithoutAChecksum() async throws {
        let descriptor = model(size: 100_000, checksum: nil)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        do {
            _ = try await manager.download(descriptor.id)
            XCTFail("a truncated download was installed")
        } catch let error as SpeechToTextError {
            guard case .modelCorrupt = error else {
                return XCTFail("expected modelCorrupt, got \(error)")
            }
        }
    }

    /// A correct checksum passes.
    func testAMatchingChecksumInstalls() async throws {
        let payload = ggmlPayload(bytes: 2048)
        let descriptor = model(
            size: 2048,
            checksum: SHA256Hash.hexDigest(of: payload)
        )
        let transport = StubTransport(behaviour: .delivers(payload))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        _ = try await manager.download(descriptor.id)
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertEqual(lifecycle, .downloaded)
    }

    /// Section 111's local sibling: a failed transfer is reported, not retried
    /// against some other source.
    func testAFailedDownloadIsReportedAsANetworkProblem() async throws {
        let descriptor = model()
        let transport = StubTransport(behaviour: .fails(.transport(reason: "offline")))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        do {
            _ = try await manager.download(descriptor.id)
            XCTFail("a failed download reported success")
        } catch let error as SpeechToTextError {
            XCTAssertEqual(error, .networkUnavailable)
        }
        let attempts = await transport.downloadCount
        XCTAssertEqual(attempts, 1, "the manager retried a download by itself")
    }

    // MARK: Compatibility

    /// Section 35 and 83. A model that will not fit is refused before the
    /// download starts, not after half a gigabyte has arrived.
    func testAModelTooLargeForTheDeviceIsRefused() async throws {
        let huge = model(id: "huge", size: 3 * 1024 * 1024 * 1024, variant: .large)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 16)))
        let (manager, store) = makeManager(
            catalog: [huge],
            transport: transport,
            device: FixedDeviceResources.smallPhone
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        do {
            _ = try await manager.download(huge.id)
            XCTFail("an oversized model was downloaded")
        } catch let error as SpeechToTextError {
            // Either verdict is correct and both stop the download; which one
            // depends on whether memory or disk runs out first on the fixture.
            switch error {
            case .modelIncompatible, .insufficientStorage:
                break
            default:
                XCTFail("expected an incompatibility, got \(error)")
            }
        }
        let attempts = await transport.downloadCount
        XCTAssertEqual(attempts, 0, "an incompatible model was fetched anyway")
    }

    /// Section 25's reasoning, as a check on the shipped catalog: nothing in it
    /// is a model a phone should not be offered.
    func testTheCuratedCatalogHoldsOnlyPhoneAppropriateModels() {
        XCTAssertFalse(LocalSpeechModelCatalog.models.isEmpty)
        for model in LocalSpeechModelCatalog.models {
            XCTAssertTrue(
                [.tiny, .base, .small].contains(model.variant),
                "\(model.displayName) is too large to offer on a phone"
            )
            XCTAssertEqual(
                model.downloadURL?.scheme, "https",
                "\(model.displayName) is not fetched over HTTPS"
            )
            XCTAssertGreaterThan(model.fileSize, 0)
        }
    }

    /// An English-only model is not offered to someone whose phone is not in
    /// English — it would install, report Ready, and transcribe nonsense.
    func testEnglishOnlyModelsAreFilteredByLocale() {
        let french = Locale(identifier: "fr_FR")
        let offered = LocalSpeechModelCatalog.models(supporting: french)

        XCTAssertFalse(offered.isEmpty, "no model at all was offered for French")
        for model in offered {
            XCTAssertFalse(model.isEnglishOnly)
        }
        // And English still gets everything.
        XCTAssertEqual(
            LocalSpeechModelCatalog.models(supporting: Locale(identifier: "en_GB")).count,
            LocalSpeechModelCatalog.models.count
        )
    }

    // MARK: Availability

    /// Section 104. No model downloaded means `needsModelDownload`, which the
    /// pipeline turns into a refusal before the microphone opens.
    func testAvailabilityIsNeedsModelDownloadBeforeAnythingIsInstalled() async {
        let transport = StubTransport(behaviour: .delivers(Data()))
        let (manager, store) = makeManager(catalog: [model()], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let availability = await manager.availability(for: nil)
        XCTAssertEqual(availability, .needsModelDownload)
    }

    /// A build with no whisper.cpp linked says so rather than offering a
    /// download that could never run.
    func testAvailabilityIsUnsupportedWithoutARuntime() async {
        let transport = StubTransport(behaviour: .delivers(Data()))
        let (manager, store) = makeManager(
            catalog: [model()],
            transport: transport,
            runtime: UnavailableLocalSpeechRuntime()
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let availability = await manager.availability(for: nil)
        guard case .unsupported = availability else {
            return XCTFail("expected unsupported, got \(availability)")
        }
    }

    // MARK: Loading and memory

    /// Section 107. An out-of-memory load fails cleanly, releases the runtime,
    /// and leaves the model installed so a smaller one can be tried.
    func testAnOutOfMemoryLoadRecoversWithoutLosingTheModel() async throws {
        let descriptor = model(size: 4096)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let runtime = MockLocalSpeechRuntime(loadFailure: .insufficientMemory)
        let (manager, store) = makeManager(
            catalog: [descriptor],
            transport: transport,
            runtime: runtime
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        _ = try await manager.download(descriptor.id)
        await manager.select(descriptor.id)

        do {
            try await manager.loadSelectedModel()
            XCTFail("a failing load reported success")
        } catch let error as SpeechToTextError {
            XCTAssertEqual(error, .insufficientMemory)
        }

        // Still on disk — the file is fine, the memory was not.
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertEqual(lifecycle, .downloaded)
        let loaded = await runtime.isModelLoaded()
        XCTAssertFalse(loaded)
        let unloads = await runtime.unloadCount
        XCTAssertGreaterThan(unloads, 0, "the runtime was not released after a failed load")
    }

    /// Section 38. Unloading releases the runtime rather than flipping a flag.
    func testUnloadingReleasesTheRuntime() async throws {
        let descriptor = model(size: 4096)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let runtime = MockLocalSpeechRuntime()
        let (manager, store) = makeManager(
            catalog: [descriptor],
            transport: transport,
            runtime: runtime
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        _ = try await manager.download(descriptor.id)
        await manager.select(descriptor.id)
        try await manager.loadSelectedModel()

        var loaded = await runtime.isModelLoaded()
        XCTAssertTrue(loaded)

        await manager.unload()
        loaded = await runtime.isModelLoaded()
        XCTAssertFalse(loaded)
        let unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    // MARK: Deletion

    /// Section 39. Deleting a speech model touches the speech model and
    /// nothing else — which is structural here, since the manager holds a store
    /// rooted at the speech directory and cannot name anything else.
    func testDeletingAModelRemovesOnlyItsFile() async throws {
        let descriptor = model(size: 4096)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        // A neighbouring file standing in for anything else in the container.
        try store.prepareDirectory()
        let bystander = store.url(forRelativePath: "not-a-speech-model.txt")
        try Data("keep me".utf8).write(to: bystander)

        _ = try await manager.download(descriptor.id)
        try await manager.delete(descriptor.id)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.url(forRelativePath: descriptor.fileName).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bystander.path),
            "deleting a speech model removed something else"
        )
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertEqual(lifecycle, .notDownloaded)
        let selected = await manager.selectedModel()
        XCTAssertNil(selected)
    }

    /// The filesystem is authoritative: a model deleted underneath the app is
    /// not still reported installed.
    func testInstalledStateIsRebuiltFromDisk() async throws {
        let descriptor = model(size: 4096)
        let transport = StubTransport(behaviour: .delivers(ggmlPayload(bytes: 4096)))
        let (manager, store) = makeManager(catalog: [descriptor], transport: transport)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        _ = try await manager.download(descriptor.id)
        try FileManager.default.removeItem(at: store.url(forRelativePath: descriptor.fileName))

        await manager.refreshInstalledState()
        let lifecycle = await manager.lifecycle(of: descriptor.id)
        XCTAssertEqual(lifecycle, .notDownloaded)
    }
}
