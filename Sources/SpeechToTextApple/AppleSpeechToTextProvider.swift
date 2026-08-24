import Foundation
import SpeechToText

/// Transcription by Apple.
///
/// ## One provider, several APIs
///
/// Section 14. The user picks "Apple Speech"; which of Apple's speech APIs
/// actually runs is this type's problem, not theirs. The chain is tried in
/// order of preference and the first one that reports itself usable for the
/// requested locale wins.
///
/// ## What it claims about privacy
///
/// Section 17, and this is the part worth being careful about. It does **not**
/// say "100% on-device". It reports what the *selected backend* reports, per
/// locale, at the moment it is asked — because `SFSpeechRecognizer` only
/// guarantees on-device processing when `supportsOnDeviceRecognition` is true
/// and the request asked for it, and neither is true everywhere. A provider
/// that promised on-device processing and then sent audio to a server would be
/// the worst privacy bug this app could ship.
public actor AppleSpeechToTextProvider: SpeechToTextProvider {

    public nonisolated let id: SpeechToTextProviderID = .apple

    /// Partial results are supported; whether audio leaves the device is not a
    /// constant, so the conservative value is declared here and the specific
    /// answer comes from `privacyStatus(for:)`.
    ///
    /// `sendsAudioOffDevice` is false because Apple's speech recognition is not
    /// this app sending audio anywhere — where a server path is used it is
    /// Apple's own, under the user's existing relationship with their device.
    /// The distinction that matters for section 47 is that *this app* uploads
    /// nothing, which is true here and false for OpenAI.
    public nonisolated let capabilities = SpeechToTextCapabilities(
        supportsPartialResults: true,
        supportsOffline: true,
        sendsAudioOffDevice: false
    )

    private let backends: [any AppleTranscriberBackend]

    public init() {
        self.backends = Self.availableBackends()
    }

    /// The chain, best first.
    ///
    /// Built once. Which entries exist depends on what this build can see; which
    /// one *runs* depends on what the device and locale support, and that is
    /// decided per session rather than here.
    static func availableBackends() -> [any AppleTranscriberBackend] {
        var backends: [any AppleTranscriberBackend] = []
        #if canImport(Speech) && canImport(AVFAudio)
        if let modern = makeModernBackend() { backends.append(modern) }
        backends.append(SFSpeechRecognizerBackend())
        #endif
        return backends
    }

    public func availability(for configuration: SpeechToTextConfiguration) async
        -> SpeechToTextAvailability
    {
        let locale = configuration.resolvedLocale()
        guard !backends.isEmpty else {
            return .unsupported(reason: "Apple Speech isn't available in this build.")
        }

        // The first backend that says yes. A backend reporting `needsPermission`
        // is *not* skipped — the next one in the chain needs the same
        // authorization, so falling through would hide the thing the user has
        // to fix.
        var firstAnswer: SpeechToTextAvailability?
        for backend in backends {
            let availability = await backend.availability(for: locale)
            if availability.isReady { return .ready }
            if case .needsPermission = availability { return availability }
            if firstAnswer == nil { firstAnswer = availability }
        }
        return firstAnswer ?? .unavailable(reason: "Apple Speech isn't available right now.")
    }

    /// The backend that would run, and whether it keeps audio on the device.
    ///
    /// Read by Settings so the privacy line describes the path that will
    /// actually be used (section 48).
    public func privacyStatus(for configuration: SpeechToTextConfiguration) async
        -> AppleSpeechPrivacyStatus
    {
        let locale = configuration.resolvedLocale()
        guard let backend = await selectBackend(for: locale) else {
            return AppleSpeechPrivacyStatus(
                summary: "Apple Speech isn't available right now.",
                isOnDevice: false
            )
        }
        let onDevice = await backend.isOnDevice(for: locale)
        return AppleSpeechPrivacyStatus(
            summary: backend.kind.privacySummary,
            // Stated only when the running backend confirms it. Section 17.
            isOnDevice: onDevice
        )
    }

    public func startSession(
        configuration: SpeechToTextConfiguration,
        audio: SpeechAudioStream
    ) async throws -> SpeechToTextSession {
        let locale = configuration.resolvedLocale()
        guard let backend = await selectBackend(for: locale) else {
            throw SpeechToTextError.providerUnavailable(
                reason: "Apple Speech isn't available right now."
            )
        }

        let (stream, emitter) = SpeechEventEmitter.makeStream()
        let sessionID = SpeechSessionID()
        let control = AppleTranscriptionControl()

        await emitter.emit(.started)

        // Apple's APIs consume audio as it arrives, so the work starts now
        // rather than at Stop. Closing the microphone ends `audio.chunks`,
        // which is what tells the backend to finalize.
        let work = Task {
            await backend.transcribe(
                audio: audio,
                locale: locale,
                wantsPartialResults: configuration.partialResultsEnabled,
                emitter: emitter,
                control: control
            )
        }

        return SpeechToTextSession(
            id: sessionID,
            providerID: id,
            events: stream,
            finish: {
                // Not cancelling the task: the audio stream has already ended
                // and the recognizer is settling on its answer. Cancelling here
                // is exactly the bug that loses the last word.
                control.finish()
            },
            cancel: {
                control.cancel()
                work.cancel()
                await emitter.cancel()
            }
        )
    }

    /// The first backend usable for this locale.
    private func selectBackend(for locale: Locale) async -> (any AppleTranscriberBackend)? {
        for backend in backends {
            if await backend.availability(for: locale).isReady { return backend }
        }
        // Nothing is ready — most often an unprompted permission. The last
        // entry is the widest-support one, so it is what will produce the most
        // accurate error when it tries.
        return backends.last
    }
}

/// What Settings says about where Apple processes audio.
public struct AppleSpeechPrivacyStatus: Hashable, Sendable {
    /// One sentence about the path in use.
    public var summary: String
    /// Whether the running backend confirms on-device processing.
    ///
    /// Nil-safe by construction: false means "not confirmed", which is what is
    /// shown, rather than "confirmed not to be".
    public var isOnDevice: Bool

    public init(summary: String, isOnDevice: Bool) {
        self.summary = summary
        self.isOnDevice = isOnDevice
    }

    /// The detail line, which never over-claims.
    public var detail: String {
        isOnDevice
            ? "Audio is processed on this iPhone."
            : "Apple may process audio on its servers for this language."
    }
}
