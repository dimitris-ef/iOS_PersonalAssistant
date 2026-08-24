import Foundation
import SpeechToText

/// Where the selected speech configuration comes from, asked fresh each time.
///
/// A closure rather than a stored value because the user can change providers
/// in Settings while the composer is on screen, and the next thing they say
/// must go to the engine they just picked — not to the one that was selected
/// when the app launched.
public typealias SpeechConfigurationSource = @Sendable () async -> SpeechToTextConfiguration

/// Part 5's recognizer, reimplemented as a pipeline over interchangeable
/// providers.
///
/// ## What this preserves
///
/// Section 1. `VoiceCoordinator`, `VoiceSession`, `VoiceState`, `VoiceEvent`,
/// the microphone button, the partial-transcript UI, Stop, Cancel, Retry and
/// the TTS interaction are all unchanged, because this conforms to the
/// `SpeechInputService` protocol they were already written against. The Part 5
/// tests run against this without modification, which is the check that the
/// preservation is real rather than claimed.
///
/// ## What it adds
///
/// The split section 1 does ask for: capture on one side, recognition on the
/// other. `startListening` opens the shared microphone *once*, resolves the
/// selected provider, and hands the samples over. Neither half knows which
/// implementation the other is.
///
/// ## Where the boundary is
///
/// The last thing this type produces is a `SpeechTranscript`, whose payload is
/// a `String`. Above it is `VoiceCoordinator`, which submits that string
/// through the same closure typed input uses. Nothing audio-shaped crosses the
/// line (section 72), because by this point nothing audio-shaped is left.
public actor SpeechPipelineInputService: SpeechInputService {

    private let microphone: any MicrophoneCaptureService
    private let registry: SpeechToTextProviderRegistry
    private let configuration: SpeechConfigurationSource

    /// The transcription in progress, if any.
    private var active: ActiveSession?

    /// One live transcription, and everything needed to end it.
    private struct ActiveSession {
        let voiceSessionID: VoiceSessionID
        let speechSession: SpeechToTextSession
        /// Pumps provider events into the delegate. Cancelled on teardown.
        let pump: Task<Void, Never>
    }

    public init(
        microphone: any MicrophoneCaptureService,
        registry: SpeechToTextProviderRegistry,
        configuration: @escaping SpeechConfigurationSource
    ) {
        self.microphone = microphone
        self.registry = registry
        self.configuration = configuration
    }

    // MARK: Permissions

    public func currentPermissions() async -> VoicePermissions {
        await permissions(prompting: false)
    }

    public func requestPermissions() async -> VoicePermissions {
        await permissions(prompting: true)
    }

    /// Reads, or asks for, both permissions voice needs.
    ///
    /// The microphone is asked of the capture service, always. Speech
    /// recognition is asked of the *provider*, because only some providers need
    /// it: Apple's older API does, whisper.cpp and OpenAI do not. Section 16 —
    /// the app must not request an authorization for a capability it will not
    /// use, and with Whisper selected there is nothing to request.
    ///
    /// A provider that needs no such permission reports `.authorized`, meaning
    /// "nothing is withholding recognition here". That is the honest reading:
    /// the combined answer decides whether listening may start, and for those
    /// providers the answer genuinely is yes.
    private func permissions(prompting: Bool) async -> VoicePermissions {
        let microphonePermission = prompting
            ? await microphone.requestPermission()
            : await microphone.currentPermission()

        let configuration = await configuration()
        guard let provider = registry.resolve(configuration) else {
            // The selected provider is not in this build. Not a permission
            // problem, and deliberately not resolved by substituting another
            // engine (section 41).
            return VoicePermissions(
                microphone: map(microphonePermission),
                speechRecognition: .unsupported
            )
        }

        let availability = await provider.availability(for: configuration)
        let speechPermission: VoicePermission
        switch availability {
        case .needsPermission(.speechRecognition):
            speechPermission = .denied
        case .needsPermission(.microphone):
            // The provider noticed the same thing the capture service did.
            speechPermission = .authorized
        case .unsupported:
            speechPermission = .unsupported
        default:
            speechPermission = .authorized
        }

        return VoicePermissions(
            microphone: map(microphonePermission),
            speechRecognition: speechPermission
        )
    }

    private func map(_ permission: MicrophonePermission) -> VoicePermission {
        switch permission {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .unsupported: return .unsupported
        }
    }

    // MARK: Availability

    public func isAvailable() async -> Bool {
        let configuration = await configuration()
        guard let provider = registry.resolve(configuration) else { return false }
        return await provider.availability(for: configuration).isReady
    }

    /// Where recognition actually happens, for the privacy screen.
    ///
    /// Derived from the selected provider's own declared capabilities rather
    /// than assumed. Section 17 and 48: a provider that sends audio off the
    /// device says so, and this reports what it says. Nothing here guesses, and
    /// nothing claims on-device processing on a provider's behalf.
    public func recognitionMode() async -> SpeechRecognitionMode {
        let configuration = await configuration()
        guard let provider = registry.resolve(configuration) else { return .unavailable }
        guard await provider.availability(for: configuration).isReady else { return .unavailable }
        return provider.capabilities.sendsAudioOffDevice ? .server : .onDevice
    }

    // MARK: Listening

    public func startListening(
        session: VoiceSessionID,
        delegate: any SpeechInputDelegate
    ) async {
        // A previous session that was never torn down would otherwise keep the
        // microphone open and keep delivering into a delegate nobody is
        // reading. Retry (section 59) reaches here with `active` still set.
        await teardown()

        let configuration = await configuration()
        guard let provider = registry.resolve(configuration) else {
            delegate.speechInput(session, didFailWith: .recognitionUnavailable)
            return
        }

        // Availability is checked before the microphone opens, so a missing
        // model or a refused credential does not light the recording indicator
        // for a session that cannot produce anything (section 104).
        let availability = await provider.availability(for: configuration)
        guard availability.isReady else {
            delegate.speechInput(session, didFailWith: voiceError(for: availability))
            return
        }

        let audio: SpeechAudioStream
        do {
            audio = try await microphone.start()
        } catch let error as SpeechToTextError {
            delegate.speechInput(session, didFailWith: Self.map(error))
            return
        } catch {
            delegate.speechInput(session, didFailWith: .audioSessionFailed)
            return
        }

        let speechSession: SpeechToTextSession
        do {
            speechSession = try await provider.startSession(
                configuration: configuration,
                audio: audio
            )
        } catch let error as SpeechToTextError {
            await microphone.cancel()
            delegate.speechInput(session, didFailWith: Self.map(error))
            return
        } catch {
            await microphone.cancel()
            delegate.speechInput(session, didFailWith: .recognitionFailed)
            return
        }

        let pump = Task { [weak self] in
            for await event in speechSession.events {
                guard !Task.isCancelled else { return }
                await self?.deliver(event, for: session, to: delegate)
            }
        }

        active = ActiveSession(
            voiceSessionID: session,
            speechSession: speechSession,
            pump: pump
        )
    }

    /// "I've finished speaking."
    ///
    /// Section 57, in order and for every provider: close the microphone first,
    /// *then* ask the provider to finalize. The order matters — a batch
    /// provider's audio stream has to end before it can transcribe, and asking
    /// it to finish while the microphone is still open would either hang or
    /// truncate the last word.
    public func stopListening() async {
        guard let active else { return }
        await microphone.stop()
        await active.speechSession.finish()
    }

    /// "Forget it."
    ///
    /// Section 58: the microphone stops, the provider's work is cancelled —
    /// which for OpenAI means the upload is aborted and the temporary file
    /// deleted, and for Whisper means the decode is abandoned — and no
    /// transcript is delivered.
    public func cancelListening() async {
        await teardown()
    }

    private func teardown() async {
        guard let session = active else { return }
        active = nil
        session.pump.cancel()
        await microphone.cancel()
        await session.speechSession.cancel()
    }

    // MARK: Delivery

    /// Turns one provider event into a Part 5 delegate callback.
    ///
    /// The stale-session guard (section 60 and 102) is here as well as in
    /// `VoiceCoordinator`. Two checks rather than one because they catch
    /// different things: the coordinator drops callbacks for a voice session
    /// the user has abandoned, and this drops events from a *transcription*
    /// that has been replaced — which happens on Retry, where the voice session
    /// is new but the old provider session may still be finishing.
    private func deliver(
        _ event: SpeechToTextEvent,
        for session: VoiceSessionID,
        to delegate: any SpeechInputDelegate
    ) async {
        guard active?.voiceSessionID == session else { return }

        switch event {
        case .started:
            break

        case .partial(let text):
            // Section 15: a partial is shown, never submitted.
            delegate.speechInput(
                session,
                didProduce: SpeechTranscript(text: text, isFinal: false, level: 0)
            )

        case .final(let text):
            active = nil
            delegate.speechInput(
                session,
                didProduce: SpeechTranscript(text: text, isFinal: true, level: 0)
            )

        case .cancelled:
            // Reached when the provider ended without a transcript — most often
            // because there was no speech in the audio. `VoiceSession` turns
            // this into "I didn't catch that" rather than an empty message
            // (section 62).
            active = nil
            delegate.speechInput(session, didFailWith: .noSpeechDetected)

        case .failed(let error):
            active = nil
            await microphone.cancel()
            delegate.speechInput(session, didFailWith: Self.map(error))
        }
    }

    /// Maps a speech error into Part 5's vocabulary.
    ///
    /// Lossy on purpose. `VoiceError` is what the composer renders and it was
    /// designed for one recognizer; the richer `SpeechToTextError` is what
    /// Settings shows, where a missing model and a refused API key genuinely
    /// need different words. Collapsing them here keeps the in-composer
    /// message short and sends the detail where it is actionable.
    static func map(_ error: SpeechToTextError) -> VoiceError {
        switch error {
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        case .speechPermissionDenied:
            return .speechPermissionDenied
        case .unsupportedDevice:
            return .unsupported
        case .noSpeechDetected:
            return .noSpeechDetected
        case .cancelled:
            return .recognitionFailed
        case .providerUnavailable, .unsupportedLocale, .modelNotDownloaded,
             .modelCorrupt, .modelIncompatible, .networkUnavailable,
             .authenticationFailed, .insufficientStorage:
            // All of these are "this provider cannot do it right now", and all
            // of them are fixed in Settings rather than by speaking again.
            return .recognitionUnavailable
        case .insufficientMemory, .transcriptionFailed:
            return .recognitionFailed
        }
    }

    private func voiceError(for availability: SpeechToTextAvailability) -> VoiceError {
        switch availability {
        case .ready:
            return .recognitionUnavailable
        case .needsPermission(.microphone):
            return .microphonePermissionDenied
        case .needsPermission(.speechRecognition):
            return .speechPermissionDenied
        case .unsupported:
            return .unsupported
        case .failed(let error):
            return Self.map(error)
        case .needsModelDownload, .modelLoading, .unavailable, .networkRequired,
             .misconfigured:
            return .recognitionUnavailable
        }
    }
}
