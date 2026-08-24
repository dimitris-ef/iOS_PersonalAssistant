import AssistantAI
import AssistantDomain
import NativeModelKit
import XCTest
@testable import AIProviderLocal

/// Downloading, verifying and installing — success and every way it fails.
///
/// Sections 94 to 97. None of this touches the network: the transport is a
/// protocol precisely so a test can make a download fail halfway, hang until
/// cancelled, or deliver bytes that are not the bytes that were promised.
/// Section 88 — CI must never fetch a multi-gigabyte model.
final class LocalModelDownloadTests: XCTestCase {
    private var store: LocalModelStore!
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    override func setUp() {
        super.setUp()
        store = LocalModelStore.temporary()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        store = nil
        super.tearDown()
    }

    private func descriptor(
        checksum: String? = nil,
        bytes: Int64? = nil,
        architecture: String = "qwen3"
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: "test-model",
            displayName: "Test Model",
            architecture: architecture,
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: bytes,
            checksumSHA256: checksum,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024
        )
    }

    private func installer() -> LocalModelInstaller {
        LocalModelInstaller(store: store, dateProvider: FixedDateProvider(now: now))
    }

    // MARK: Success

    /// Section 94: download, progress, checksum, verify, atomic install.
    func testAGoodDownloadIsVerifiedAndInstalled() async throws {
        let payload = GGUFFixture.header()
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(
            transport: transport,
            dateProvider: FixedDateProvider(now: now)
        )

        let progress = ProgressRecorder()
        let descriptor = descriptor(
            checksum: SHA256Hash.hexDigest(of: payload),
            bytes: Int64(payload.count)
        )
        let file = try await manager.download(descriptor) { progress.record($0) }
        let record = try installer().install(
            file,
            descriptor: descriptor,
            device: FixedDeviceResources.largePhone
        )

        XCTAssertEqual(record.id, descriptor.id)
        XCTAssertEqual(record.fileSizeBytes, Int64(payload.count))
        XCTAssertTrue(record.checksumWasDeclared)
        XCTAssertEqual(record.architecture, "qwen3")
        XCTAssertEqual(record.quantization, "Q4_K_M")
        XCTAssertTrue(store.fileExists(record))
        // The temporary file is gone: it was moved, not copied.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))

        // Section 19: progress reached the caller, and finished at 100%.
        XCTAssertFalse(progress.updates.isEmpty)
        XCTAssertEqual(progress.updates.last?.fractionComplete, 1.0)
    }

    /// Section 22's "no checksum" case: verification is not skipped, it is
    /// weaker, and the record says which happened.
    func testAModelWithNoPublishedChecksumIsStillStructurallyVerified() async throws {
        let payload = GGUFFixture.header()
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(transport: transport)

        let descriptor = descriptor(checksum: nil, bytes: Int64(payload.count))
        let file = try await manager.download(descriptor) { _ in }
        let record = try installer().install(
            file,
            descriptor: descriptor,
            device: FixedDeviceResources.largePhone
        )

        XCTAssertFalse(record.checksumWasDeclared)
        // The digest of what arrived is still recorded, so a later integrity
        // check has a baseline.
        XCTAssertNotNil(record.checksumSHA256)
        XCTAssertEqual(record.checksumSHA256, SHA256Hash.hexDigest(of: payload))
    }

    // MARK: Failure

    /// Section 95. A transfer that fails leaves nothing installed and an error
    /// worth offering "Try again" for.
    func testANetworkFailureInstallsNothing() async {
        let transport = FakeDownloadTransport(
            result: .failure(LocalModelDownloadError.transport(reason: "The network connection was lost."))
        )
        let manager = LocalModelDownloadManager(transport: transport)

        do {
            _ = try await manager.download(descriptor()) { _ in }
            XCTFail("expected the download to fail")
        } catch let error as LocalModelDownloadError {
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(store.orphanedFiles(knownPaths: []).isEmpty, "nothing reached the store")
    }

    func testAnHTTPErrorIsRetryable() async {
        let transport = FakeDownloadTransport(result: .failure(LocalModelDownloadError.httpStatus(503)))
        let manager = LocalModelDownloadManager(transport: transport)

        do {
            _ = try await manager.download(descriptor()) { _ in }
            XCTFail("expected the download to fail")
        } catch let error as LocalModelDownloadError {
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Section 75. Plain HTTP is refused before a single byte moves.
    func testAnInsecureURLIsRefused() async {
        var insecure = descriptor()
        insecure.downloadURL = URL(string: "http://example.invalid/model.gguf")
        let transport = FakeDownloadTransport(result: .success(Data()))
        let manager = LocalModelDownloadManager(transport: transport)

        do {
            _ = try await manager.download(insecure) { _ in }
            XCTFail("expected an insecure URL to be refused")
        } catch let error as LocalModelDownloadError {
            guard case .invalidURL = error else {
                return XCTFail("expected invalidURL, got \(error)")
            }
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(transport.attempts, 0, "nothing should have been requested")
    }

    // MARK: Corruption

    /// Section 97. Wrong digest: rejected, deleted, and never loadable.
    func testAChecksumMismatchIsRejectedAndTheFileDeleted() async throws {
        let payload = GGUFFixture.header()
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(transport: transport)

        let descriptor = descriptor(
            checksum: String(repeating: "a", count: 64),
            bytes: Int64(payload.count)
        )
        let file = try await manager.download(descriptor) { _ in }

        XCTAssertThrowsError(
            try installer().install(
                file,
                descriptor: descriptor,
                device: FixedDeviceResources.largePhone
            )
        ) { error in
            guard case .checksumMismatch = error as? LocalModelDownloadError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "the bad file must go")
        XCTAssertTrue(store.orphanedFiles(knownPaths: []).isEmpty, "nothing reached the store")
    }

    /// Section 23 and 24: bytes that are not a model at all.
    func testANonModelPayloadIsRejected() async throws {
        let payload = GGUFFixture.notAModel()
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(transport: transport)

        let descriptor = descriptor(bytes: Int64(payload.count))
        let file = try await manager.download(descriptor) { _ in }

        XCTAssertThrowsError(
            try installer().install(
                file,
                descriptor: descriptor,
                device: FixedDeviceResources.largePhone
            )
        ) { error in
            guard case .notAModel = error as? LocalModelDownloadError else {
                return XCTFail("expected notAModel, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    /// Section 116. A valid model that is the *wrong* model.
    func testAnArchitectureMismatchFailsTheInstall() async throws {
        let payload = GGUFFixture.header(architecture: "gemma3")
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(transport: transport)

        let descriptor = descriptor(bytes: Int64(payload.count), architecture: "qwen3")
        let file = try await manager.download(descriptor) { _ in }

        XCTAssertThrowsError(
            try installer().install(
                file,
                descriptor: descriptor,
                device: FixedDeviceResources.largePhone
            )
        ) { error in
            guard case .modelMismatch = error as? LocalModelDownloadError else {
                return XCTFail("expected modelMismatch, got \(error)")
            }
        }
    }

    /// A size that is merely surprising is a note, not a failure — catalogs are
    /// maintained by hand and a re-quantized upload moves by a percent.
    func testASizeDiscrepancyIsRecordedNotFatal() async throws {
        let payload = GGUFFixture.header()
        let transport = FakeDownloadTransport(result: .success(payload))
        let manager = LocalModelDownloadManager(transport: transport)

        let descriptor = descriptor(bytes: Int64(payload.count) * 4)
        let file = try await manager.download(descriptor) { _ in }
        let verification = try installer().verify(file, against: descriptor)

        XCTAssertFalse(verification.discrepancies.isEmpty)
        try? FileManager.default.removeItem(at: file.url)
    }

    // MARK: Cancellation

    /// Section 96. Cancelling leaves the model not installed and the state
    /// clean enough to try again.
    func testCancellingADownloadInstallsNothing() async throws {
        let transport = FakeDownloadTransport(result: .hang)
        let manager = LocalModelDownloadManager(transport: transport)
        let descriptor = descriptor()

        let download = Task { try await manager.download(descriptor) { _ in } }
        // Wait for the transport to actually be in flight, rather than sleeping
        // a fixed time and hoping.
        try await transport.waitUntilStarted()
        await manager.cancel(descriptor.id, url: descriptor.downloadURL)

        do {
            _ = try await download.value
            XCTFail("expected cancellation")
        } catch let error as LocalModelDownloadError {
            guard case .cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }

        let installed = await manager.isDownloading(descriptor.id)
        XCTAssertFalse(installed)
        XCTAssertTrue(store.orphanedFiles(knownPaths: []).isEmpty)
    }

    /// Section 21. Resume data is kept when the transport produces it, so the
    /// next attempt does not start from zero.
    func testResumeDataIsKeptAcrossACancellation() async throws {
        let transport = FakeDownloadTransport(result: .hang, resumeData: Data("resume".utf8))
        let manager = LocalModelDownloadManager(transport: transport)
        let descriptor = descriptor()

        let download = Task { try await manager.download(descriptor) { _ in } }
        try await transport.waitUntilStarted()
        await manager.cancel(descriptor.id, url: descriptor.downloadURL)
        _ = try? await download.value

        let canResume = await manager.canResume(descriptor.id)
        XCTAssertTrue(canResume)

        await manager.discardResumeData(for: descriptor.id)
        let afterDiscard = await manager.canResume(descriptor.id)
        XCTAssertFalse(afterDiscard)
    }

    // MARK: Storage housekeeping

    /// Section 114. A `.part` file nobody owns does not live forever.
    func testOrphanedFilesAreCleanedUp() throws {
        try store.prepareDirectory()
        let stray = store.url(forRelativePath: "leftover.part")
        try Data("junk".utf8).write(to: stray)
        let kept = store.url(forRelativePath: "keep.gguf")
        try GGUFFixture.header().write(to: kept)

        let removed = store.removeOrphanedFiles(knownPaths: ["keep.gguf"])

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    /// Re-downloading replaces the file rather than accumulating copies.
    func testInstallingTwiceLeavesOneFile() throws {
        let first = try GGUFFixture.write(GGUFFixture.header())
        _ = try store.install(first, as: "model.gguf")
        let second = try GGUFFixture.write(GGUFFixture.header(name: "Newer"))
        _ = try store.install(second, as: "model.gguf")

        let contents = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(contents.count, 1)
    }
}

// MARK: - Doubles

/// A transport that produces exactly what a test asks for.
private final class FakeDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    enum Result {
        case success(Data)
        case failure(Error)
        /// Blocks until `cancel` is called.
        case hang
    }

    private let result: Result
    private let resumeData: Data?
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private(set) var attempts = 0

    init(result: Result, resumeData: Data? = nil) {
        self.result = result
        self.resumeData = resumeData
    }

    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        lock.lock()
        attempts += 1
        started = true
        lock.unlock()

        switch result {
        case .success(let data):
            // A handful of progress callbacks, as a real transfer produces.
            let total = Int64(data.count)
            for step in 1...4 {
                onProgress(
                    LocalModelDownloadProgress(
                        bytesReceived: total * Int64(step) / 4,
                        bytesExpected: total
                    )
                )
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-\(UUID().uuidString).part")
            try data.write(to: file)
            return DownloadedFile(url: file, byteCount: total)

        case .failure(let error):
            throw error

        case .hang:
            while true {
                lock.lock()
                let isCancelled = cancelled
                lock.unlock()
                if isCancelled { throw LocalModelDownloadError.cancelled }
                try await Task.sleep(nanoseconds: 500_000)
            }
        }
    }

    func cancel(url: URL) async -> Data? {
        lock.lock()
        cancelled = true
        lock.unlock()
        return resumeData
    }

    /// Blocks until `download` has actually begun.
    ///
    /// Polling a flag rather than sleeping a fixed interval: a fixed sleep is
    /// either too short on a loaded CI machine or wasted time on a fast one,
    /// and this is the difference between a flaky test and a fast one.
    func waitUntilStarted() async throws {
        for _ in 0..<2_000 {
            lock.lock()
            let isStarted = started
            lock.unlock()
            if isStarted { return }
            try await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("the download never started")
    }
}

/// Collects progress callbacks from whichever executor they arrive on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalModelDownloadProgress] = []

    var updates: [LocalModelDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: LocalModelDownloadProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
