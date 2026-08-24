import Foundation
import SpeechToText

#if canImport(Speech) && canImport(AVFAudio)
import AVFAudio
import Speech

extension AppleSpeechToTextProvider {
    /// The current-generation backend, when this OS has one.
    ///
    /// Section 11 asks that `SpeechAnalyzer` be preferred where supported.
    /// "Where supported" is doing real work in that sentence: the app deploys
    /// to iOS 17, the modern stack arrived in iOS 26, and even on iOS 26 it
    /// covers a subset of locales and needs assets that may not be installed.
    /// So it is one entry in a chain rather than a replacement, and this
    /// returns nil on everything older.
    static func makeModernBackend() -> (any AppleTranscriberBackend)? {
        if #available(iOS 26.0, macOS 26.0, *) {
            return SpeechAnalyzerBackend()
        }
        return nil
    }
}

/// Transcription over `SpeechAnalyzer` and `SpeechTranscriber`.
///
/// The API this app would use everywhere if it could: async-native, explicit
/// about which text is volatile and which is finalized, and explicit about the
/// locale assets it needs rather than silently falling back to a server.
///
/// TODO-DEVICE: none of this has run. Whether the asset installation request
/// completes on a real device, how far behind the speaker volatile results
/// arrive, and which locales report themselves installed all need an iPhone —
/// see `Docs/SPEECH.md`.
@available(iOS 26.0, macOS 26.0, *)
struct SpeechAnalyzerBackend: AppleTranscriberBackend {
    let kind: AppleTranscriberKind = .speechAnalyzer

    func availability(for locale: Locale) async -> SpeechToTextAvailability {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied:
            return .needsPermission(.speechRecognition)
        case .restricted:
            return .unsupported(reason: "Speech recognition is restricted on this device.")
        case .notDetermined, .authorized:
            break
        @unknown default:
            return .unsupported(reason: "Speech recognition is unavailable on this device.")
        }

        // Section 12: asked, not assumed. A locale this build has never heard
        // of is a perfectly ordinary thing for a user to have selected.
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { Self.matches($0, locale) }) else {
            return .unsupported(reason: "Apple's newer speech engine doesn't cover this language.")
        }

        // Section 13: an asset that is not installed yet is a *preparation*
        // state, not readiness. Reporting Ready here and then failing at the
        // moment the user speaks is exactly what that section forbids.
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { Self.matches($0, locale) }) else {
            return .unavailable(reason: "Preparing speech recognition for this language…")
        }
        return .ready
    }

    func isOnDevice(for locale: Locale) async -> Bool {
        // Only claimed when the assets are actually installed. Section 17:
        // an installed-asset transcription is the on-device path; without them
        // this backend is not the one that runs anyway.
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { Self.matches($0, locale) }
    }

    /// Asks the system to fetch the assets this locale needs.
    ///
    /// Section 13's supported workflow. Returns whether anything is now
    /// installed; the caller shows a truthful preparation state either way and
    /// never shows "Ready" on the strength of having *started* a download.
    static func prepareAssets(for locale: Locale) async -> Bool {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        if let request = try? await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try? await request.downloadAndInstall()
        }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { matches($0, locale) }
    }

    func transcribe(
        audio: SpeechAudioStream,
        locale: Locale,
        wantsPartialResults: Bool,
        emitter: SpeechEventEmitter,
        control: AppleTranscriptionControl
    ) async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Volatile results are Apple's name for partials. Asked for only
            // when the caller wants them, so a final-only configuration does
            // not pay for text it will discard.
            reportingOptions: wantsPartialResults ? [.volatileResults] : [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) {
            inputContinuation = $0
        }
        guard let inputContinuation else {
            await emitter.fail(
                .providerUnavailable(reason: "Apple Speech couldn't start.")
            )
            return
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            await emitter.fail(
                .providerUnavailable(reason: "Apple Speech couldn't start.")
            )
            return
        }

        // Results and audio run concurrently: the analyzer publishes while the
        // microphone is still open, which is what makes partials live.
        let results = Task {
            do {
                for try await result in transcriber.results {
                    if control.isCancelled { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await emitter.finish(with: text)
                    } else {
                        await emitter.emit(.partial(text))
                    }
                }
            } catch {
                guard !control.isCancelled else { return }
                await emitter.fail(
                    .transcriptionFailed(reason: "That didn't come through clearly.")
                )
            }
        }

        for await chunk in audio.chunks {
            if control.isCancelled { break }
            if let buffer = SFSpeechRecognizerBackend.makeBuffer(from: chunk) {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
        inputContinuation.finish()

        if control.isCancelled {
            results.cancel()
            try? await analyzer.cancelAndFinishNow()
            await emitter.cancel()
            return
        }

        // The audio has ended. This is what asks the analyzer to settle and
        // publish its last, finalized result — the moment Stop turns into a
        // transcript (section 57).
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value

        // A run that ended without a final result produced nothing usable. The
        // emitter has already swallowed anything terminal, so this is a no-op
        // in the normal case and a truthful failure in the abnormal one.
        if await !emitter.isFinished {
            await emitter.cancel()
        }
    }

    /// Compares locales by language, ignoring region.
    ///
    /// `en_GB` and `en_US` are the same recognition support as far as this
    /// decision goes, and requiring an exact match would report "unsupported"
    /// to a British user because the list happens to name `en-US`.
    static func matches(_ candidate: Locale, _ wanted: Locale) -> Bool {
        func language(_ locale: Locale) -> String {
            let identifier = locale.identifier
            let head = identifier
                .components(separatedBy: CharacterSet(charactersIn: "-_"))
                .first ?? identifier
            return head.lowercased()
        }
        return language(candidate) == language(wanted)
    }
}
#endif
