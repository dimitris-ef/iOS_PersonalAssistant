import Foundation
import SpeechToText

/// Transcription on this phone, with a downloaded Whisper model.
///
/// ## The hard requirement this type carries
///
/// Section 40 and 41. Once a model is installed, transcription works with no
/// network at all — and when it *fails*, it fails. There is no path from here
/// to OpenAI. That is not enforced by a flag: this type does not hold a URL
/// session, a credential, or a reference to another provider, and
/// `SpeechToTextLocal` does not depend on `SpeechToTextOpenAI`. Uploading the
/// user's audio as a fallback is not something this code could do if it wanted
/// to.
///
/// ## Why it produces a final transcript only
///
/// Section 55. whisper.cpp decodes a 30-second window at a time; streaming
/// partial results means re-decoding overlapping windows and reconciling
/// transcripts that disagree at the seams. Done carelessly it produces text
/// that reads fluently and says something the user did not, which is worse than
/// no partials at all. So `supportsPartialResults` is false, honestly, and the
/// composer shows "Transcribing…" after Stop rather than inventing live text
/// (section 53).
public actor LocalSpeechToTextProvider: SpeechToTextProvider {

    public nonisolated let id: SpeechToTextProviderID = .localWhisper

    public nonisolated let capabilities = SpeechToTextCapabilities(
        supportsPartialResults: false,
        supportsOffline: true,
        // The claim that matters, and it is true structurally rather than by
        // assertion — see the type note.
        sendsAudioOffDevice: false,
        requiresModelDownload: true
    )

    private let models: LocalSpeechModelManager
    private let runtime: any LocalSpeechRuntime
    /// The transcription in flight, so Cancel can reach it.
    private var current: SpeechSessionID?

    public init(models: LocalSpeechModelManager, runtime: any LocalSpeechRuntime) {
        self.models = models
        self.runtime = runtime
    }

    public func availability(for configuration: SpeechToTextConfiguration) async
        -> SpeechToTextAvailability
    {
        await models.availability(for: configuration.locale)
    }

    public func startSession(
        configuration: SpeechToTextConfiguration,
        audio: SpeechAudioStream
    ) async throws -> SpeechToTextSession {
        let (stream, emitter) = SpeechEventEmitter.makeStream()
        let sessionID = SpeechSessionID()
        current = sessionID

        await emitter.emit(.started)

        // Collect first, transcribe on `finish()`. The audio stream ends when
        // the microphone closes, so this task completes exactly when the user
        // stops speaking — which is what makes Stop the moment work begins.
        let collector = Task {
            await SpeechAudioConverter.collect(audio, as: .whisper)
        }

        let work = TranscriptionWork(
            models: models,
            runtime: runtime,
            locale: configuration.locale,
            collector: collector,
            emitter: emitter
        )

        return SpeechToTextSession(
            id: sessionID,
            providerID: id,
            events: stream,
            finish: { await work.run() },
            cancel: { [weak self] in
                await work.cancel()
                await self?.clear(sessionID)
            }
        )
    }

    private func clear(_ id: SpeechSessionID) {
        if current == id { current = nil }
    }
}

/// One transcription, from collected audio to a transcript.
///
/// Separated from the provider so the `finish` and `cancel` closures capture
/// *this* rather than the provider actor — a session that outlives its provider
/// (which happens when the user switches providers mid-utterance) must still be
/// cancellable, and must not keep the provider alive to do it.
private actor TranscriptionWork {
    private let models: LocalSpeechModelManager
    private let runtime: any LocalSpeechRuntime
    private let locale: Locale?
    private let collector: Task<SpeechAudioChunk, Never>
    private let emitter: SpeechEventEmitter

    private var isCancelled = false
    private var hasRun = false

    init(
        models: LocalSpeechModelManager,
        runtime: any LocalSpeechRuntime,
        locale: Locale?,
        collector: Task<SpeechAudioChunk, Never>,
        emitter: SpeechEventEmitter
    ) {
        self.models = models
        self.runtime = runtime
        self.locale = locale
        self.collector = collector
        self.emitter = emitter
    }

    /// Loads the model if needed, transcribes, and emits exactly one outcome.
    func run() async {
        // Section 61's guard, at the level where a second Stop could otherwise
        // start a second decode of the same audio.
        guard !hasRun, !isCancelled else { return }
        hasRun = true

        let audio = await collector.value
        guard !isCancelled else { return }

        guard !audio.samples.isEmpty else {
            // The microphone produced nothing. Not a failure — the emitter
            // turns this into "I didn't catch that".
            await emitter.cancel()
            return
        }

        do {
            try await models.loadSelectedModel()
            guard !isCancelled else { return }

            let transcript = try await runtime.transcribe(
                samples: audio.samples,
                locale: locale
            )
            guard !isCancelled else { return }
            await emitter.finish(with: normalize(transcript))
        } catch let error as SpeechToTextError {
            guard !isCancelled else { return }
            // Section 41, again, at the moment it would matter most: a local
            // failure is reported as a local failure. The audio is discarded,
            // not redirected.
            await emitter.fail(error)
        } catch {
            guard !isCancelled else { return }
            await emitter.fail(
                .transcriptionFailed(reason: "On-device transcription didn't complete.")
            )
        }
    }

    func cancel() async {
        isCancelled = true
        collector.cancel()
        await runtime.cancelTranscription()
        await emitter.cancel()
    }

    /// Section 76's "safe normalization", and no more.
    ///
    /// Whisper prefixes segments with a leading space and joins them without
    /// one, so raw output is `" Remind me tomorrow. Then call."` with doubled
    /// spaces at the seams. Collapsing runs of whitespace and trimming is
    /// repairing the *format*; it does not touch a single word, and nothing
    /// here re-punctuates, re-capitalises or paraphrases (section 75).
    nonisolated func normalize(_ transcript: String) -> String {
        transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
