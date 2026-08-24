import Foundation

/// One selectable speech model, described without reference to any engine.
///
/// Section 6. Not every provider fills in every field, and that is deliberate:
/// Apple exposes no meaningful model choice, OpenAI exposes named cloud models
/// with no size, and Whisper exposes downloadable files with a size, a
/// quantization and a RAM cost. One descriptor with optional fields is honest
/// about that; three parallel types would push the difference into the UI,
/// which is exactly where section 56 says it must not go.
public struct SpeechToTextModelDescriptor: Hashable, Sendable, Identifiable {
    public var id: SpeechModelIdentifier
    public var providerID: SpeechToTextProviderID
    public var displayName: String
    /// One line for the picker. Never marketing.
    public var summary: String

    /// Whether using this model requires fetching a file first.
    public var downloadRequired: Bool
    /// Bytes to fetch. Nil for cloud models, which download nothing.
    public var downloadSize: Int64?
    /// Peak resident bytes, estimated conservatively. Nil where it does not
    /// apply.
    public var estimatedRAM: Int64?

    public var supportsPartialResults: Bool
    public var supportsOffline: Bool

    /// Language codes the model handles, or nil for "not constrained here".
    ///
    /// A multilingual Whisper build reports nil rather than enumerating
    /// ninety-nine languages nobody will read.
    public var supportedLanguages: [String]?

    public init(
        id: SpeechModelIdentifier,
        providerID: SpeechToTextProviderID,
        displayName: String,
        summary: String,
        downloadRequired: Bool = false,
        downloadSize: Int64? = nil,
        estimatedRAM: Int64? = nil,
        supportsPartialResults: Bool = false,
        supportsOffline: Bool = false,
        supportedLanguages: [String]? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.summary = summary
        self.downloadRequired = downloadRequired
        self.downloadSize = downloadSize
        self.estimatedRAM = estimatedRAM
        self.supportsPartialResults = supportsPartialResults
        self.supportsOffline = supportsOffline
        self.supportedLanguages = supportedLanguages
    }

    /// Whether this model claims to handle a locale.
    ///
    /// Unconstrained models answer true. A model that lists languages is
    /// matched on the language code alone — `en-GB` and `en-US` are the same
    /// Whisper model, and requiring an exact region match would reject a
    /// perfectly good model for a British user.
    public func supports(_ locale: Locale) -> Bool {
        guard let supportedLanguages else { return true }
        let code = languageCode(of: locale)
        return supportedLanguages.contains { $0.lowercased() == code }
    }

    private func languageCode(of locale: Locale) -> String {
        // `Locale.LanguageCode` is iOS 16+, and this target deploys wider and
        // builds on Linux, so the identifier is split by hand. `en_GB` and
        // `en-GB` both yield `en`.
        let identifier = locale.identifier
        let separators = CharacterSet(charactersIn: "-_")
        let head = identifier.components(separatedBy: separators).first ?? identifier
        return head.lowercased()
    }
}

/// Human-readable byte sizes for model rows.
///
/// Deliberately decimal (1 MB = 1,000,000 bytes), because that is what the
/// hosting provider's page says the file is and a user comparing the two
/// numbers should see them agree.
public enum SpeechModelByteFormat {
    public static func string(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0
            ? "\(Int(value)) \(units[unit])"
            : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }
}
