import Foundation
import XCTest

@testable import SpeechToText

/// The abstraction itself: identifiers, the event contract, and the guarantees
/// that hold for every provider because they are implemented once.
final class SpeechToTextAbstractionTests: XCTestCase {

    // MARK: Identifiers

    /// Section 5. These strings are written to the user's settings and read
    /// back by a later build, so they are pinned by a test rather than left to
    /// whoever next edits the enum.
    func testProviderIdentifiersArePersistableAndStable() throws {
        XCTAssertEqual(SpeechToTextProviderID.apple.rawValue, "apple")
        XCTAssertEqual(SpeechToTextProviderID.localWhisper.rawValue, "localWhisper")
        XCTAssertEqual(SpeechToTextProviderID.openAI.rawValue, "openAI")

        // Round-trips as a bare string, not as a wrapped object, so a settings
        // file stays readable.
        let encoded = try JSONEncoder().encode(SpeechToTextProviderID.localWhisper)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"localWhisper\"")
        let decoded = try JSONDecoder().decode(SpeechToTextProviderID.self, from: encoded)
        XCTAssertEqual(decoded, .localWhisper)
    }

    /// Section 5 again, from the other side: no identifier is display text.
    func testNoProviderIdentifierIsDisplayText() {
        for id in [
            SpeechToTextProviderID.apple, .localWhisper, .openAI, .mock,
        ] {
            XCTAssertFalse(id.rawValue.contains(" "), "\(id) looks like a label, not an identity")
        }
    }

    // MARK: The event contract

    /// Section 61. The emitter is where the duplicate-final guard lives, so it
    /// holds for every provider rather than three times over.
    func testASecondFinalIsIgnored() async {
        let (stream, emitter) = SpeechEventEmitter.makeStream()

        await emitter.finish(with: "Remind me tomorrow to call the dentist.")
        await emitter.finish(with: "Remind me tomorrow to call the dentist.")

        var events: [SpeechToTextEvent] = []
        for await event in stream { events.append(event) }

        XCTAssertEqual(events, [.final("Remind me tomorrow to call the dentist.")])
    }

    /// Section 62. An empty transcript is not a transcript. If this let an
    /// empty string through, the voice layer would create a blank user message
    /// and the assistant would answer a question nobody asked.
    func testAnEmptyFinalBecomesCancellation() async {
        let (stream, emitter) = SpeechEventEmitter.makeStream()
        await emitter.finish(with: "   \n  ")

        var events: [SpeechToTextEvent] = []
        for await event in stream { events.append(event) }

        XCTAssertEqual(events, [.cancelled])
    }

    /// A final transcript arrives trimmed — section 76's "safe normalization",
    /// and nothing beyond it.
    func testTheFinalTranscriptIsTrimmedButNotRewritten() async {
        let (stream, emitter) = SpeechEventEmitter.makeStream()
        await emitter.finish(with: "  set an alarm for seven tomorrow  ")

        var events: [SpeechToTextEvent] = []
        for await event in stream { events.append(event) }

        // Trimmed. Not capitalised, not punctuated, not paraphrased.
        XCTAssertEqual(events, [.final("set an alarm for seven tomorrow")])
    }

    /// Nothing follows a terminal event, whatever the provider does next.
    func testEventsAfterCancellationAreDropped() async {
        let (stream, emitter) = SpeechEventEmitter.makeStream()

        await emitter.emit(.partial("Remind me"))
        await emitter.cancel()
        await emitter.emit(.partial("Remind me tomorrow"))
        await emitter.finish(with: "Remind me tomorrow to call the dentist.")

        var events: [SpeechToTextEvent] = []
        for await event in stream { events.append(event) }

        XCTAssertEqual(events, [.partial("Remind me"), .cancelled])
    }

    // MARK: The mock provider

    /// Section 99. Partials arrive, then exactly one final.
    func testTheMockProviderEmitsPartialsThenOneFinal() async throws {
        let provider = MockSpeechToTextProvider(
            behaviour: .transcribes(
                partials: ["Remind me tomorrow", "Remind me tomorrow to call"],
                final: "Remind me tomorrow to call the dentist."
            )
        )
        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .mock),
            audio: .empty()
        )
        await session.finish()

        var events: [SpeechToTextEvent] = []
        for await event in session.events { events.append(event) }

        XCTAssertEqual(
            events,
            [
                .started,
                .partial("Remind me tomorrow"),
                .partial("Remind me tomorrow to call"),
                .final("Remind me tomorrow to call the dentist."),
            ]
        )
        XCTAssertEqual(events.filter { if case .final = $0 { return true } else { return false } }
            .count, 1)
    }

    /// Section 101, at the provider level: a provider that calls back twice
    /// still produces one final.
    func testADuplicateFinalFromTheProviderIsCollapsed() async throws {
        let provider = MockSpeechToTextProvider(
            behaviour: .emitsDuplicateFinal("Set an alarm for seven.")
        )
        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .mock),
            audio: .empty()
        )
        await session.finish()

        var finals: [String] = []
        for await event in session.events {
            if case .final(let text) = event { finals.append(text) }
        }
        XCTAssertEqual(finals, ["Set an alarm for seven."])
    }

    /// Cancel produces no transcript. The one guarantee section 58 turns on.
    func testCancellingProducesNoFinal() async throws {
        let provider = MockSpeechToTextProvider(
            behaviour: .transcribes(partials: ["Remind me"], final: "Remind me to do it.")
        )
        let session = try await provider.startSession(
            configuration: SpeechToTextConfiguration(providerID: .mock),
            audio: .empty()
        )
        await session.cancel()

        for await event in session.events {
            if case .final = event { XCTFail("a cancelled session produced a transcript") }
        }
        let cancels = await provider.cancelCount
        XCTAssertEqual(cancels, 1)
    }

    // MARK: The registry

    /// Section 4. The registry hands back exactly what was asked for.
    func testTheRegistryResolvesTheSelectedProvider() async {
        let apple = MockSpeechToTextProvider(id: .apple)
        let local = MockSpeechToTextProvider(id: .localWhisper)
        let openAI = MockSpeechToTextProvider(id: .openAI)
        let registry = SpeechToTextProviderRegistry(providers: [apple, local, openAI])

        XCTAssertEqual(registry.order, [.apple, .localWhisper, .openAI])
        XCTAssertEqual(
            registry.resolve(SpeechToTextConfiguration(providerID: .localWhisper))?.id,
            .localWhisper
        )
    }

    /// Section 41, at its root. A selected provider that is not in this build
    /// resolves to *nothing* — never to whichever provider happens to be first.
    ///
    /// If this returned a substitute, a build where the local runtime failed to
    /// link would quietly begin uploading the user's audio to OpenAI.
    func testAMissingProviderDoesNotFallBackToAnother() {
        let openAI = MockSpeechToTextProvider(id: .openAI)
        let registry = SpeechToTextProviderRegistry(providers: [openAI])

        let resolved = registry.resolve(
            SpeechToTextConfiguration(providerID: .localWhisper)
        )
        XCTAssertNil(resolved, "a missing speech provider silently resolved to another one")
    }

    // MARK: Audio conversion

    /// Section 10. Stereo at 48 kHz becomes mono at 16 kHz, which is what
    /// whisper.cpp requires and what the shared path normalizes to.
    func testStereoIsDownmixedAndResampled() {
        let frames = 480
        var interleaved: [Float] = []
        for index in 0..<frames {
            interleaved.append(Float(index % 10) / 10)   // left
            interleaved.append(Float(index % 10) / 10)   // right, identical
        }
        let chunk = SpeechAudioChunk(
            samples: interleaved,
            format: SpeechAudioFormat(sampleRate: 48_000, channelCount: 2)
        )

        let converted = SpeechAudioConverter.convert(chunk, to: .whisper)

        XCTAssertEqual(converted.format, .whisper)
        // 480 stereo frames at 48 kHz is 10 ms, which is 160 samples at 16 kHz.
        XCTAssertEqual(converted.samples.count, 160)
        XCTAssertEqual(converted.duration, 0.01, accuracy: 0.0005)
    }

    /// Already-correct audio is passed through untouched rather than resampled
    /// back and forth.
    func testMatchingFormatIsNotConverted() {
        let chunk = SpeechAudioChunk(samples: [0.1, 0.2, 0.3], format: .whisper)
        let converted = SpeechAudioConverter.convert(chunk, to: .whisper)
        XCTAssertEqual(converted.samples, [0.1, 0.2, 0.3])
    }

    /// Section 49 and 78, as a bound rather than a promise: a recording left
    /// running cannot grow without limit.
    func testCollectingIsBoundedByDuration() async {
        let second = [Float](repeating: 0.2, count: 16_000)
        let chunks = (0..<10).map { _ in SpeechAudioChunk(samples: second, format: .whisper) }

        let collected = await SpeechAudioConverter.collect(
            .fixed(chunks, format: .whisper),
            as: .whisper,
            maximumDuration: 3
        )

        XCTAssertEqual(collected.samples.count, 48_000)
        XCTAssertEqual(collected.duration, 3, accuracy: 0.001)
    }

    /// Silence reads as no level; speech-shaped audio reads as some.
    func testLevelTracksLoudness() {
        let silence = SpeechAudioChunk(
            samples: [Float](repeating: 0, count: 100), format: .whisper
        )
        let speech = SpeechAudioChunk(
            samples: [Float](repeating: 0.2, count: 100), format: .whisper
        )
        XCTAssertEqual(silence.level, 0)
        XCTAssertGreaterThan(speech.level, 0.5)
        XCTAssertLessThanOrEqual(speech.level, 1)
    }

    // MARK: Errors

    /// Section 112. Every speech error is a speech-configuration problem, so
    /// nothing in this family can send the user to change the assistant's
    /// model settings.
    func testEverySpeechErrorIsASpeechProblem() {
        let errors: [SpeechToTextError] = [
            .microphonePermissionDenied, .speechPermissionDenied,
            .providerUnavailable(reason: "x"), .unsupportedDevice(reason: "x"),
            .unsupportedLocale("Welsh"), .modelNotDownloaded,
            .modelCorrupt(reason: "x"), .modelIncompatible(reason: "x"),
            .insufficientMemory, .insufficientStorage(reason: "x"),
            .networkUnavailable, .authenticationFailed(reason: "x"),
            .transcriptionFailed(reason: "x"), .noSpeechDetected, .cancelled,
        ]
        for error in errors {
            XCTAssertTrue(error.isSpeechConfigurationProblem)
            XCTAssertFalse(error.message.isEmpty, "\(error) has nothing to show the user")
        }
    }

    /// Section 52. No provider's internal vocabulary leaks into a message a
    /// person reads.
    func testErrorMessagesCarryNoDiagnostics() {
        let errors: [SpeechToTextError] = [
            .networkUnavailable, .noSpeechDetected, .insufficientMemory,
            .modelNotDownloaded, .modelCorrupt(reason: "bad digest"),
        ]
        for error in errors {
            let message = error.message.lowercased()
            for leak in ["nserror", "http", "errno", "domain", "whisper", "sfspeech"] {
                XCTAssertFalse(
                    message.contains(leak),
                    "\(error) leaks \(leak) into a user-facing sentence"
                )
            }
        }
    }
}
