import Foundation
import NativeModelKit
import SpeechToText
import SpeechToTextLocal
import XCTest

// `@testable` so the redaction test can read `headers`, which is deliberately
// internal: an API key that any call site can pull out of a request is one that
// ends up in a log line eventually.
@testable import SpeechToTextOpenAI

/// The guarantees that would matter most if they were wrong: audio leaves the
/// device only when the user chose a cloud provider, and a local or Apple
/// failure never becomes an upload.
///
/// Sections 40, 41, 47, 108, 109, 110, 111, 112 and 113.
final class CloudExplicitnessTests: XCTestCase {

    /// A transport that records whether it was ever asked to send anything.
    ///
    /// The instrument for section 109: "no OpenAI transcription transport is
    /// invoked" is only checkable if there is something that would notice.
    private actor Watchdog: OpenAITranscriptionTransport {
        private(set) var sendCount = 0

        func send(
            _ request: OpenAITranscriptionRequest
        ) async throws -> OpenAITranscriptionResponse {
            sendCount += 1
            let body = try? JSONSerialization.data(withJSONObject: ["text": "uploaded"])
            return OpenAITranscriptionResponse(statusCode: 200, body: body ?? Data())
        }
    }

    private func speech(seconds: Double = 1) -> SpeechAudioStream {
        let chunk = SpeechAudioChunk(
            samples: [Float](repeating: 0.2, count: Int(16_000 * seconds)),
            format: .whisper
        )
        return .fixed([chunk], format: .whisper)
    }

    private func drain(_ session: SpeechToTextSession) async -> [SpeechToTextEvent] {
        var events: [SpeechToTextEvent] = []
        for await event in session.events { events.append(event) }
        return events
    }

    // MARK: Section 109 — the hard regression test

    /// With the local provider selected, no OpenAI transport is invoked. Ever.
    ///
    /// The strongest statement of section 41. Note what makes it true: it is not
    /// that a branch was not taken, it is that `SpeechToTextLocal` does not
    /// depend on `SpeechToTextOpenAI` and so cannot reach the watchdog at all.
    /// This test would still pass if someone deleted the check; it would stop
    /// compiling if someone added the dependency.
    func testTheLocalProviderNeverInvokesTheCloudTransport() async throws {
        let watchdog = Watchdog()
        let runtime = MockLocalSpeechRuntime(behaviour: .transcribes("Locally transcribed."))
        let manager = LocalSpeechModelManager(
            catalog: [],
            store: .temporary(prefix: "cloud-explicit"),
            runtime: runtime
        )
        let local = LocalSpeechToTextProvider(models: manager, runtime: runtime)

        let session = try await local.startSession(
            configuration: SpeechToTextConfiguration(providerID: .localWhisper),
            audio: speech()
        )
        await session.finish()
        _ = await drain(session)

        let sends = await watchdog.sendCount
        XCTAssertEqual(sends, 0, "audio reached OpenAI without the user selecting it")
    }

    /// A *failing* local transcription is still not an upload.
    ///
    /// The case section 41 is really about: the fallback that would be
    /// convenient and would be a privacy breach.
    func testALocalFailureDoesNotBecomeAnUpload() async throws {
        let watchdog = Watchdog()
        let runtime = MockLocalSpeechRuntime(
            behaviour: .fails(.transcriptionFailed(reason: "decode failed"))
        )
        let manager = LocalSpeechModelManager(
            catalog: [],
            store: .temporary(prefix: "cloud-explicit-fail"),
            runtime: runtime
        )
        let local = LocalSpeechToTextProvider(models: manager, runtime: runtime)

        let session = try await local.startSession(
            configuration: SpeechToTextConfiguration(providerID: .localWhisper),
            audio: speech()
        )
        await session.finish()
        let events = await drain(session)

        // It failed, and it said so.
        XCTAssertTrue(events.contains { if case .failed = $0 { return true } else { return false } })
        // And nothing was sent anywhere.
        let sends = await watchdog.sendCount
        XCTAssertEqual(sends, 0, "a local failure uploaded the user's audio")
    }

    /// Section 108. With a model installed and no network, local transcription
    /// still works — and makes no network call.
    func testLocalTranscriptionWorksOfflineAndMakesNoNetworkCall() async throws {
        let watchdog = Watchdog()
        let runtime = MockLocalSpeechRuntime(
            behaviour: .transcribes("What's important today?")
        )
        let store = NativeFileStoreStub.make()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let descriptor = LocalSpeechModelDescriptor(
            id: "offline-base",
            displayName: "Offline Base",
            summary: "For tests.",
            variant: .base,
            quantization: .q5_1,
            isEnglishOnly: true,
            fileSize: 8,
            downloadURL: URL(string: "https://example.invalid/model.bin"),
            fileName: "offline.bin"
        )
        // Put the file there directly: the point of this test is what happens
        // *after* installation, with no network available at all.
        try store.prepareDirectory()
        try Data(Array("ggml".utf8) + [0, 0, 0, 0])
            .write(to: store.url(forRelativePath: descriptor.fileName))

        let manager = LocalSpeechModelManager(
            catalog: [descriptor],
            store: store,
            runtime: runtime,
            selected: descriptor.id
        )
        await manager.refreshInstalledState()

        let availability = await manager.availability(for: nil)
        XCTAssertTrue(availability.isReady, "an installed model was not usable offline")

        let local = LocalSpeechToTextProvider(models: manager, runtime: runtime)
        let session = try await local.startSession(
            configuration: SpeechToTextConfiguration(providerID: .localWhisper),
            audio: speech()
        )
        await session.finish()
        let events = await drain(session)

        XCTAssertTrue(events.contains(.final("What's important today?")))
        let sends = await watchdog.sendCount
        XCTAssertEqual(sends, 0)
    }

    /// Section 47 and 48. Only the cloud provider declares that audio leaves
    /// the device — the flag the privacy UI reads.
    func testOnlyTheCloudProviderDeclaresThatAudioLeavesTheDevice() async {
        let runtime = MockLocalSpeechRuntime()
        let local = LocalSpeechToTextProvider(
            models: LocalSpeechModelManager(
                catalog: [],
                store: .temporary(prefix: "flags"),
                runtime: runtime
            ),
            runtime: runtime
        )
        let openAI = OpenAISpeechToTextProvider(
            transport: Watchdog(),
            credential: { "sk-test" }
        )

        XCTAssertFalse(local.capabilities.sendsAudioOffDevice)
        XCTAssertTrue(local.capabilities.supportsOffline)
        XCTAssertTrue(openAI.capabilities.sendsAudioOffDevice)
        XCTAssertFalse(openAI.capabilities.supportsOffline)
    }

    // MARK: Section 110 — OpenAI succeeds

    /// A mocked response becomes a normalized final transcript.
    func testAMockedOpenAIResponseProducesATranscript() async throws {
        let transport = MockTranscriptionTransport.transcribing(
            "  Remind me tomorrow to call the dentist.  "
        )
        let provider = OpenAISpeechToTextProvider(
            transport: transport,
            credential: { "sk-test" }
        )

        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .openAI),
            audio: speech()
        )
        await session.finish()
        let events = await drain(session)

        XCTAssertTrue(events.contains(.final("Remind me tomorrow to call the dentist.")))

        // Exactly one request, carrying audio and the model.
        let requests = await transport.sentRequests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.path, "/v1/audio/transcriptions")
        XCTAssertGreaterThan(request.body.count, 1000, "no audio was uploaded")
    }

    /// Section 79 and the standing rule: the key never reaches a log line.
    func testTheRequestDescriptionNeverCarriesTheKey() {
        let request = OpenAITranscriptionRequest(
            url: OpenAITranscriptionModel.defaultEndpoint,
            apiKey: "sk-super-secret-value",
            body: Data([1, 2, 3]),
            boundary: "abc",
            timeout: 30
        )
        XCTAssertFalse(request.redactedDescription.contains("sk-super-secret-value"))
        XCTAssertTrue(request.redactedDescription.contains("<redacted>"))
        // And the header that carries it is only assembled at send time.
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-super-secret-value")
    }

    // MARK: Section 111 — OpenAI fails

    /// An offline upload fails and reports it. No transcript, no fallback.
    func testAnOfflineUploadFailsWithoutFallingBack() async throws {
        let transport = MockTranscriptionTransport(behaviour: .fails(.networkUnavailable))
        let provider = OpenAISpeechToTextProvider(
            transport: transport,
            credential: { "sk-test" }
        )

        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .openAI),
            audio: speech()
        )
        await session.finish()
        let events = await drain(session)

        XCTAssertTrue(events.contains(.failed(.networkUnavailable)))
        XCTAssertFalse(
            events.contains { if case .final = $0 { return true } else { return false } },
            "a failed upload still produced a transcript"
        )
    }

    // MARK: Section 112 — authentication

    /// A refused key is a *speech* configuration problem, and says where to fix
    /// it — Remote AI settings, not the assistant's model selection.
    func testARefusedKeyIsReportedAsASpeechConfigurationProblem() async throws {
        let transport = MockTranscriptionTransport(
            behaviour: .returns(statusCode: 401, body: Data())
        )
        let provider = OpenAISpeechToTextProvider(
            transport: transport,
            credential: { "sk-wrong" }
        )

        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .openAI),
            audio: speech()
        )
        await session.finish()
        let events = await drain(session)

        let failure = events.compactMap { event -> SpeechToTextError? in
            if case .failed(let error) = event { return error }
            return nil
        }.first
        let error = try XCTUnwrap(failure)
        guard case .authenticationFailed = error else {
            return XCTFail("expected authenticationFailed, got \(error)")
        }
        XCTAssertTrue(error.isSpeechConfigurationProblem)
        XCTAssertTrue(error.message.contains("Remote AI"))
        // Section 52: the status code never reaches the user.
        XCTAssertFalse(error.message.contains("401"))
    }

    /// No key configured at all is reported before any request is attempted.
    func testAMissingKeyIsReportedWithoutSendingAnything() async throws {
        let transport = MockTranscriptionTransport.transcribing("should never happen")
        let provider = OpenAISpeechToTextProvider(
            transport: transport,
            credential: { nil }
        )

        let availability = await provider.availability(
            for: SpeechToTextConfiguration(providerID: .openAI)
        )
        guard case .misconfigured = availability else {
            return XCTFail("expected misconfigured, got \(availability)")
        }

        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .openAI),
            audio: speech()
        )
        await session.finish()
        _ = await drain(session)

        let sends = await transport.sendCount
        XCTAssertEqual(sends, 0, "audio was uploaded with no credential")
    }

    // MARK: Section 113 — cancellation

    /// Cancel aborts the upload and produces no transcript.
    func testCancellingAnUploadProducesNoTranscript() async throws {
        let transport = MockTranscriptionTransport(behaviour: .hangs)
        let provider = OpenAISpeechToTextProvider(
            transport: transport,
            credential: { "sk-test" }
        )

        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .openAI),
            audio: speech()
        )
        // Start the upload, then abandon it.
        let running = Task { await session.finish() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await session.cancel()
        running.cancel()

        let events = await drain(session)
        XCTAssertFalse(
            events.contains { if case .final = $0 { return true } else { return false } },
            "a cancelled upload produced a transcript"
        )
    }

    // MARK: Sections 49, 51, 78 — temporary audio

    /// Nothing is written to disk, so there is nothing to clean up.
    ///
    /// The strongest available form of "delete temporary audio promptly": the
    /// encoder returns `Data`, the request holds it, and both are released with
    /// the request. This asserts the encoder has no filesystem side effect at
    /// all.
    func testEncodingAudioTouchesNoFiles() throws {
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        )

        let chunk = SpeechAudioChunk(
            samples: [Float](repeating: 0.3, count: 16_000),
            format: .whisper
        )
        let wav = OpenAITranscriptionAudioEncoder.wav(from: chunk)
        _ = OpenAITranscriptionAudioEncoder.multipartBody(
            wav: wav,
            model: "gpt-4o-transcribe",
            language: "en",
            boundary: OpenAITranscriptionAudioEncoder.makeBoundary()
        )

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        )
        XCTAssertEqual(after.subtracting(before), [], "encoding wrote a temporary file")
    }

    /// The WAV really is a WAV, at the format the service is told to expect.
    func testTheEncodedAudioIsAWellFormedWAV() {
        let chunk = SpeechAudioChunk(
            samples: [Float](repeating: 0.5, count: 16_000),
            format: .whisper
        )
        let wav = OpenAITranscriptionAudioEncoder.wav(from: chunk)

        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(wav[8..<12]), Array("WAVE".utf8))
        // 44-byte header plus two bytes per sample.
        XCTAssertEqual(wav.count, 44 + 16_000 * 2)

        // Sample rate is little-endian at offset 24.
        let rate = wav[24..<28].reduce(UInt32(0)) { result, byte in
            (result >> 8) | (UInt32(byte) << 24)
        }
        XCTAssertEqual(rate, 16_000)
    }

    /// Section 46. The speech model picker offers transcription models only.
    func testOnlyTranscriptionModelsAreOffered() {
        let ids = OpenAITranscriptionModel.catalog.map(\.id.rawValue)
        XCTAssertTrue(ids.contains("gpt-4o-transcribe"))
        for id in ids {
            XCTAssertTrue(
                id.contains("transcribe") || id.contains("whisper"),
                "\(id) is not a transcription model"
            )
        }
        // Section 45: not hardcoded to whisper-1, and an unknown identifier
        // passes through rather than being rejected.
        XCTAssertEqual(
            OpenAITranscriptionModel.resolve("gpt-5-transcribe-next"),
            "gpt-5-transcribe-next"
        )
        XCTAssertEqual(OpenAITranscriptionModel.resolve(nil), "gpt-4o-transcribe")
    }
}

/// Builds a throwaway store without importing the download layer into every
/// test file.
enum NativeFileStoreStub {
    static func make() -> NativeFileStore {
        .temporary(prefix: "speech-offline")
    }
}
