import Foundation

/// The voice layer, assembled.
///
/// The counterpart of `PlatformServices` for speech: one place that decides
/// which implementation the app gets, so the composition root stays a single
/// line and no view ever names a concrete service.
public struct VoiceServices: Sendable {
    public let input: any SpeechInputService
    public let output: (any SpeechOutputService)?

    public init(input: any SpeechInputService, output: (any SpeechOutputService)? = nil) {
        self.input = input
        self.output = output
    }

    /// Real speech recognition and synthesis.
    ///
    /// ## Choosing an implementation
    ///
    /// There is one recognition implementation today —
    /// `AppleSpeechInputService`, over `SFSpeechRecognizer` — and this is where
    /// a second would be chosen between. The obvious candidate is iOS 26's
    /// `SpeechAnalyzer` with a `SpeechTranscriber` module, which is a genuinely
    /// better API: it is `async`-native, it reports volatile and finalised
    /// ranges properly instead of a stream of whole-string guesses, and its
    /// locale assets are managed explicitly.
    ///
    /// It is not implemented here, and the reason is worth stating rather than
    /// leaving as an absence. The app deploys to iOS 17, so `SFSpeechRecognizer`
    /// is required for the great majority of supported devices no matter what;
    /// the modern stack would be an *addition*, not a replacement. That means
    /// two implementations of the same feature, and neither of them can be run
    /// from this development environment — CI has no microphone. Shipping one
    /// unverified speech path is a known risk; shipping two doubles it while
    /// halving the chance either gets device-tested properly.
    ///
    /// The seam is `SpeechInputService`. Adding the modern path later means
    /// writing one type and extending the branch below. Nothing above the
    /// protocol changes — which is the same bet the `AIProvider` abstraction
    /// made, and it paid off when Apple's on-device model arrived.
    ///
    /// On a platform with no Speech framework at all, the microphone button is
    /// shown disabled with a truthful reason rather than opening a session that
    /// was never going to work.
    public static func live(locale: Locale = Locale.current) -> VoiceServices {
        #if os(iOS) && canImport(Speech) && canImport(AVFAudio)
        return VoiceServices(
            input: AppleSpeechInputService(locale: locale),
            output: AppleSpeechOutputService()
        )
        #else
        return VoiceServices(input: UnavailableSpeechInputService(), output: nil)
        #endif
    }

    /// Deterministic services for tests, previews and CI.
    ///
    /// The screenshot pipeline uses this: a GitHub runner has no microphone, and
    /// the voice UI still has to render.
    public static func mock(
        permissions: VoicePermissions = VoicePermissions(
            microphone: .authorized,
            speechRecognition: .authorized
        )
    ) -> VoiceServices {
        VoiceServices(
            input: MockSpeechInputService(permissions: permissions),
            output: MockSpeechOutputService()
        )
    }
}
