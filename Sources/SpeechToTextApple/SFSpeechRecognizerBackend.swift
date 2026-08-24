import Foundation
import SpeechToText

#if canImport(Speech) && canImport(AVFAudio)
import AVFAudio
import Speech

/// Transcription over `SFSpeechRecognizer`.
///
/// The compatibility path, and the one that runs on every device this app
/// deploys to. Carried over from Part 5's working implementation, with one
/// substantial change: it no longer opens the microphone. Audio arrives as
/// samples from the shared capture service and is converted into the buffers
/// Apple's request wants, which is what lets three engines share one microphone
/// (section 9).
///
/// TODO-DEVICE: as in Part 5, nothing here has ever seen real audio. How far
/// behind the speaker partial results lag, and whether the on-device path is
/// selected on a given device and locale, need an iPhone.
struct SFSpeechRecognizerBackend: AppleTranscriberBackend {
    let kind: AppleTranscriberKind = .speechRecognizer

    func availability(for locale: Locale) async -> SpeechToTextAvailability {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied:
            return .needsPermission(.speechRecognition)
        case .restricted:
            return .unsupported(reason: "Speech recognition is restricted on this device.")
        case .notDetermined:
            // Not an error: the prompt appears when the user taps the
            // microphone, which is the contextual moment section 16 asks for.
            break
        case .authorized:
            break
        @unknown default:
            return .unsupported(reason: "Speech recognition is unavailable on this device.")
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            // `init(locale:)` returns nil for a locale with no recognition
            // support at all — section 12, reported rather than crashed on.
            return .unsupported(
                reason: "Apple Speech doesn't support \(languageName(for: locale))."
            )
        }
        guard recognizer.isAvailable else {
            // Genuinely transient: a server-backed recognizer goes unavailable
            // when the network does and comes back.
            return .unavailable(reason: "Apple Speech isn't available right now.")
        }
        return .ready
    }

    func isOnDevice(for locale: Locale) async -> Bool {
        // Both halves matter: the recognizer must support it *and* the request
        // must ask for it. This backend does ask (below), so this is the honest
        // answer rather than an optimistic one.
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    func transcribe(
        audio: SpeechAudioStream,
        locale: Locale,
        wantsPartialResults: Bool,
        emitter: SpeechEventEmitter,
        control: AppleTranscriptionControl
    ) async {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            await emitter.fail(
                .providerUnavailable(reason: "Apple Speech isn't available right now.")
            )
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = wantsPartialResults
        if recognizer.supportsOnDeviceRecognition {
            // Asked for whenever it is possible. The privacy claim in Settings
            // is only true because of this line.
            request.requiresOnDeviceRecognition = true
        }

        let relay = ResultRelay(emitter: emitter, control: control)
        let task = recognizer.recognitionTask(with: request) { result, error in
            Task { await relay.handle(result: result, error: error) }
        }

        // Feed the shared capture stream into Apple's request.
        for await chunk in audio.chunks {
            if control.isCancelled { break }
            if let buffer = Self.makeBuffer(from: chunk) {
                request.append(buffer)
            }
        }

        if control.isCancelled {
            task.cancel()
            request.endAudio()
            await emitter.cancel()
            return
        }

        // The microphone has closed. Tell the recognizer no more audio is
        // coming and let it settle — the final result arrives through the
        // callback, which is why this does not emit anything itself.
        request.endAudio()

        // Bounded wait. Without it a recognizer that never calls back — which
        // happens when the session is torn down underneath it — would leave the
        // UI in "Transcribing…" permanently.
        await relay.waitForCompletion(timeout: 20)
        if await !relay.hasFinished {
            task.cancel()
            await emitter.fail(
                .transcriptionFailed(reason: "That didn't come through clearly.")
            )
        }
    }

    /// Builds an `AVAudioPCMBuffer` from normalized samples.
    ///
    /// The conversion boundary section 10 asks for, on this side. Returns nil
    /// rather than trapping when the format cannot be built: a dropped buffer
    /// costs a fraction of a second of audio, while a crash costs the session.
    static func makeBuffer(from chunk: SpeechAudioChunk) -> AVAudioPCMBuffer? {
        guard !chunk.samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.format.sampleRate,
            channels: AVAudioChannelCount(max(1, chunk.format.channelCount)),
            interleaved: false
        ) else { return nil }

        let frames = chunk.samples.count / max(1, chunk.format.channelCount)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              )
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return nil }

        let channelCount = max(1, chunk.format.channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                channels[channel][frame] = chunk.samples[frame * channelCount + channel]
            }
        }
        return buffer
    }

    private func languageName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? "that language"
    }
}

/// Turns `SFSpeechRecognizer`'s callbacks into events, exactly once.
///
/// `SFSpeechRecognitionTask` delivers both a final result *and* a completion
/// callback, and can deliver a result after cancellation. The emitter already
/// guards against a second terminal event; this additionally tracks completion
/// so the caller knows whether to give up waiting.
private actor ResultRelay {
    private let emitter: SpeechEventEmitter
    private let control: AppleTranscriptionControl
    private(set) var hasFinished = false

    init(emitter: SpeechEventEmitter, control: AppleTranscriptionControl) {
        self.emitter = emitter
        self.control = control
    }

    func handle(result: SFSpeechRecognitionResult?, error: (any Error)?) async {
        guard !hasFinished, !control.isCancelled else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                hasFinished = true
                await emitter.finish(with: text)
                return
            }
            // Section 15: shown, never submitted.
            await emitter.emit(.partial(text))
            return
        }

        guard let error else { return }
        hasFinished = true
        await emitter.fail(Self.map(error))
    }

    /// Waits for a terminal callback, or gives up.
    func waitForCompletion(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasFinished, Date() < deadline, !control.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Maps Apple's speech errors into this app's vocabulary.
    ///
    /// Section 52. `NSError` domains, numeric codes and — worst of all —
    /// descriptions that sometimes contain the user's own dictated words must
    /// not reach a SwiftUI alert.
    static func map(_ error: any Error) -> SpeechToTextError {
        let nsError = error as NSError
        // 203 "no speech detected" and 1110 "no speech" are the two codes the
        // recognizer uses for silence. Neither is a failure worth alarming
        // anybody about.
        if nsError.domain == "kAFAssistantErrorDomain",
           nsError.code == 203 || nsError.code == 1110 {
            return .noSpeechDetected
        }
        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable
        }
        return .transcriptionFailed(reason: "That didn't come through clearly.")
    }
}
#endif
