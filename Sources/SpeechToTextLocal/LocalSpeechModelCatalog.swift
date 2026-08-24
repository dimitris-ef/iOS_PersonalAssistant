import Foundation
import SpeechToText

/// The speech models this app offers.
///
/// ## Why a dedicated catalog
///
/// Section 27. Part 10 has a catalog of chat models and this is not it. They
/// are hosted differently, sized differently, validated differently and chosen
/// for different reasons, and — the part that matters for the product — a user
/// picking a transcription model is making a completely separate decision from
/// a user picking an assistant model. Two lists, two screens, two selections.
///
/// ## What is in it, and what is not
///
/// Section 25: phone-appropriate models only. `tiny`, `base` and `small` are
/// here; `medium` and `large` are not. On an iPhone `medium` is roughly
/// eighteen times real time even with Metal, which for a ten-second utterance
/// is three minutes of the user watching a spinner — a model that technically
/// runs and practically does not.
///
/// ## Where the numbers come from
///
/// The `f16` sizes are the ones whisper.cpp's own README publishes and are
/// exact. The `q5_1` size is derived from the quantization ratio rather than
/// measured — this development environment cannot reach the model host, so it
/// could not be verified here. `LocalSpeechModelInstaller` tolerates a
/// discrepancy and rejects anything beyond it, so a wrong number produces a
/// clear failure rather than a silently mis-sized download. Recorded in
/// `Docs/OPEN-ITEMS.md`; the exact figure and the publisher's checksums should
/// be filled in before this ships.
public enum LocalSpeechModelCatalog {

    /// Where the ggml Whisper builds are published.
    ///
    /// The upstream project's own repository, which is what
    /// `models/download-ggml-model.sh` in whisper.cpp fetches from. HTTPS only,
    /// enforced by the download layer.
    static let host = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    /// The curated list, in the order the picker shows them.
    ///
    /// Ordered smallest-first: the decision a user is making is "how much am I
    /// willing to wait and store", and the cheap answer should be the one they
    /// see first.
    public static let models: [LocalSpeechModelDescriptor] = [
        LocalSpeechModelDescriptor(
            id: "whisper-tiny-en",
            displayName: "Whisper Tiny (English)",
            summary: "Fastest and smallest. Good for short, clear commands.",
            variant: .tiny,
            quantization: .f16,
            isEnglishOnly: true,
            fileSize: 75 * mebibyte,
            checksum: nil,
            downloadURL: URL(string: "\(host)/ggml-tiny.en.bin"),
            fileName: "ggml-tiny.en.bin"
        ),
        LocalSpeechModelDescriptor(
            id: "whisper-base-en-q5-1",
            displayName: "Whisper Base (English, compressed)",
            summary: "Base accuracy at about half the size. A good default.",
            variant: .base,
            quantization: .q5_1,
            isEnglishOnly: true,
            // Derived: base f16 is 142 MiB at 16 bits per weight; q5_1 is
            // about 6, and the non-weight parts of the file do not shrink.
            fileSize: 57 * mebibyte,
            checksum: nil,
            downloadURL: URL(string: "\(host)/ggml-base.en-q5_1.bin"),
            fileName: "ggml-base.en-q5_1.bin"
        ),
        LocalSpeechModelDescriptor(
            id: "whisper-base-en",
            displayName: "Whisper Base (English)",
            summary: "More accurate than Tiny. Handles natural speech well.",
            variant: .base,
            quantization: .f16,
            isEnglishOnly: true,
            fileSize: 142 * mebibyte,
            checksum: nil,
            downloadURL: URL(string: "\(host)/ggml-base.en.bin"),
            fileName: "ggml-base.en.bin"
        ),
        LocalSpeechModelDescriptor(
            id: "whisper-base-multilingual",
            displayName: "Whisper Base (multilingual)",
            summary: "Base accuracy across many languages.",
            variant: .base,
            quantization: .f16,
            isEnglishOnly: false,
            fileSize: 142 * mebibyte,
            checksum: nil,
            downloadURL: URL(string: "\(host)/ggml-base.bin"),
            fileName: "ggml-base.bin"
        ),
        LocalSpeechModelDescriptor(
            id: "whisper-small-en",
            displayName: "Whisper Small (English)",
            summary: "The most accurate model that is still practical on a phone.",
            variant: .small,
            quantization: .f16,
            isEnglishOnly: true,
            fileSize: 466 * mebibyte,
            checksum: nil,
            downloadURL: URL(string: "\(host)/ggml-small.en.bin"),
            fileName: "ggml-small.en.bin"
        ),
    ]

    private static let mebibyte: Int64 = 1024 * 1024

    /// The model a user gets if they turn on local speech and pick nothing.
    ///
    /// Base-English-compressed: the smallest model that transcribes ordinary
    /// conversational speech reliably, at a size most people will accept
    /// downloading over cellular.
    public static let defaultModelID: SpeechModelIdentifier = "whisper-base-en-q5-1"

    public static func model(for id: SpeechModelIdentifier) -> LocalSpeechModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The models that can transcribe a given locale.
    ///
    /// An English-only model is not offered to someone whose phone is in
    /// French: it would download, install, report Ready, and then transcribe
    /// their French as phonetically-similar English words — which looks like a
    /// broken app rather than a wrong choice.
    public static func models(supporting locale: Locale) -> [LocalSpeechModelDescriptor] {
        models.filter { $0.supports(locale) }
    }
}
