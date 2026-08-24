import Foundation
import SpeechToText

/// Where the transcription credential comes from.
///
/// A closure rather than a `CredentialStore` reference, for two reasons.
/// Section 43: the key must stay in the existing Keychain-backed architecture,
/// and injecting a reader means this provider never learns *where* it is
/// stored, so it cannot accidentally be given a second home. Section 69: the
/// app wires this to the credential the user already entered in Remote AI
/// settings, so there is no second API-key screen to fill in.
///
/// Returning nil means "not configured", which the provider reports as
/// `misconfigured` rather than attempting an unauthenticated request.
public typealias SpeechCredentialSource = @Sendable () async -> String?

/// Transcription by OpenAI.
///
/// ## Why this is not `RemoteAIProvider`
///
/// Section 42 and 71. They talk to the same company over the same protocol with
/// the same credential, and they are still two different things: one turns
/// audio into text and the other reasons about the text. Merging them would
/// have meant a single provider selection — pick OpenAI for transcription and
/// you have picked it for reasoning too — which is the exact coupling this
/// milestone exists to remove.
///
/// The shared parts are shared: the credential, and HTTPS. `SpeechToTextOpenAI`
/// does not depend on `AIProviderRemote`, so this type cannot name
/// `RemoteAIProvider`, which is what the architecture test asserts.
///
/// ## What leaves the device, and when
///
/// Section 47. Audio is uploaded only while this provider is the selected one —
/// the user's own explicit choice. Nothing else in the app can reach this type:
/// it is constructed once, put in the speech registry under `openAI`, and
/// resolved only when that is what the settings say. There is no fallback path
/// into it from Apple or from local Whisper (section 41).
public actor OpenAISpeechToTextProvider: SpeechToTextProvider {

    public nonisolated let id: SpeechToTextProviderID = .openAI

    public nonisolated let capabilities = SpeechToTextCapabilities(
        supportsPartialResults: false,
        supportsOffline: false,
        // The declaration the privacy UI reads, and the one the
        // cloud-explicitness test asserts is unique to this provider.
        sendsAudioOffDevice: true
    )

    private let transport: any OpenAITranscriptionTransport
    private let credential: SpeechCredentialSource
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(
        transport: any OpenAITranscriptionTransport = URLSessionTranscriptionTransport(),
        credential: @escaping SpeechCredentialSource,
        endpoint: URL = OpenAITranscriptionModel.defaultEndpoint,
        timeout: TimeInterval = 60
    ) {
        self.transport = transport
        self.credential = credential
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func availability(for configuration: SpeechToTextConfiguration) async
        -> SpeechToTextAvailability
    {
        guard let key = await credential(), !key.isEmpty else {
            return .misconfigured(
                reason: "Add an OpenAI API key in Remote AI settings to use this."
            )
        }
        // Deliberately not a reachability probe. Network state changes between
        // the check and the request, so a probe would be a slower way of being
        // wrong; the request itself reports the truth, and its failure is
        // handled honestly (section 111).
        return .ready
    }

    public func startSession(
        configuration: SpeechToTextConfiguration,
        audio: SpeechAudioStream
    ) async throws -> SpeechToTextSession {
        let (stream, emitter) = SpeechEventEmitter.makeStream()
        let sessionID = SpeechSessionID()

        await emitter.emit(.started)

        // Accumulate while the user speaks; encode once at Stop (section 50).
        let collector = Task {
            await SpeechAudioConverter.collect(
                audio,
                as: OpenAITranscriptionAudioEncoder.uploadFormat
            )
        }

        let upload = UploadWork(
            transport: transport,
            credential: credential,
            endpoint: endpoint,
            timeout: timeout,
            model: OpenAITranscriptionModel.resolve(configuration.modelID),
            locale: configuration.locale,
            collector: collector,
            emitter: emitter
        )

        return SpeechToTextSession(
            id: sessionID,
            providerID: id,
            events: stream,
            finish: { await upload.run() },
            cancel: { await upload.cancel() }
        )
    }
}

/// One upload, from collected audio to a transcript.
private actor UploadWork {
    private let transport: any OpenAITranscriptionTransport
    private let credential: SpeechCredentialSource
    private let endpoint: URL
    private let timeout: TimeInterval
    private let model: String
    private let locale: Locale?
    private let collector: Task<SpeechAudioChunk, Never>
    private let emitter: SpeechEventEmitter

    private var request: Task<Void, Never>?
    private var isCancelled = false
    private var hasRun = false

    init(
        transport: any OpenAITranscriptionTransport,
        credential: @escaping SpeechCredentialSource,
        endpoint: URL,
        timeout: TimeInterval,
        model: String,
        locale: Locale?,
        collector: Task<SpeechAudioChunk, Never>,
        emitter: SpeechEventEmitter
    ) {
        self.transport = transport
        self.credential = credential
        self.endpoint = endpoint
        self.timeout = timeout
        self.model = model
        self.locale = locale
        self.collector = collector
        self.emitter = emitter
    }

    func run() async {
        guard !hasRun, !isCancelled else { return }
        hasRun = true

        let audio = await collector.value
        guard !isCancelled else { return }
        guard !audio.samples.isEmpty else {
            await emitter.cancel()
            return
        }

        guard let key = await credential(), !key.isEmpty else {
            await emitter.fail(
                .authenticationFailed(
                    reason: "Add an OpenAI API key in Remote AI settings to use this."
                )
            )
            return
        }

        // Encoded here and held only for the duration of the request. Never
        // written to disk (sections 49 and 78), so there is nothing to clean up
        // and nothing left behind if the app is killed mid-upload.
        let boundary = OpenAITranscriptionAudioEncoder.makeBoundary()
        let body = OpenAITranscriptionAudioEncoder.multipartBody(
            wav: OpenAITranscriptionAudioEncoder.wav(from: audio),
            model: model,
            language: OpenAITranscriptionAudioEncoder.languageCode(for: locale),
            boundary: boundary
        )

        let request = OpenAITranscriptionRequest(
            url: endpoint,
            apiKey: key,
            body: body,
            boundary: boundary,
            timeout: timeout
        )

        // Held as a task so Cancel can abort the upload in flight rather than
        // waiting for it to finish and then discarding the answer (section 51).
        let task = Task { [transport, emitter] in
            do {
                let response = try await transport.send(request)
                guard !Task.isCancelled else { return }
                try Task.checkCancellation()

                guard response.isSuccess else {
                    await emitter.fail(Self.error(for: response))
                    return
                }
                guard let transcript = Self.transcript(from: response.body) else {
                    await emitter.fail(
                        .transcriptionFailed(
                            reason: "The transcription service returned an unexpected response."
                        )
                    )
                    return
                }
                await emitter.finish(with: transcript)
            } catch let error as SpeechToTextError {
                guard !Task.isCancelled else { return }
                // Section 111, and it is the whole point of this branch: the
                // failure is reported. There is no Apple fallback here and no
                // local fallback here, because a user who chose to send their
                // audio to OpenAI did not thereby choose to send it anywhere
                // else, and one who is offline is not helped by a silent switch
                // they never see.
                await emitter.fail(error)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await emitter.fail(
                    .transcriptionFailed(reason: "Transcription didn't complete.")
                )
            }
        }
        self.request = task
        await task.value
    }

    func cancel() async {
        isCancelled = true
        collector.cancel()
        request?.cancel()
        request = nil
        await emitter.cancel()
    }

    /// Reads the transcript out of a successful response.
    ///
    /// Only `text` is read. The response may carry more — timings, log
    /// probabilities, a language guess — and section 72 says none of it may
    /// reach the assistant, so none of it is decoded.
    static func transcript(from body: Data) -> String? {
        struct Payload: Decodable { let text: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return nil
        }
        return payload.text
    }

    /// Maps an HTTP status onto something worth showing.
    ///
    /// Section 52: the code itself never reaches the UI. What reaches it is the
    /// action the user can take.
    static func error(for response: OpenAITranscriptionResponse) -> SpeechToTextError {
        switch response.statusCode {
        case 401, 403:
            return .authenticationFailed(
                reason: "Your OpenAI key was refused. Check it in Remote AI settings."
            )
        case 413:
            return .transcriptionFailed(
                reason: "That recording was too long to transcribe. Try a shorter one."
            )
        case 429:
            return .transcriptionFailed(
                reason: "OpenAI is rate-limiting transcription. Try again shortly."
            )
        case 500...599:
            return .transcriptionFailed(
                reason: "The transcription service is having trouble. Try again shortly."
            )
        default:
            return .transcriptionFailed(reason: "Transcription didn't complete.")
        }
    }
}
