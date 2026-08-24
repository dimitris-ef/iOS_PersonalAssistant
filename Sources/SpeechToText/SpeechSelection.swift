import Foundation

/// What the user has chosen for transcription.
///
/// ## Why this is a separate value from the assistant's selection
///
/// Section 70 asks that `selectedSpeechProvider` and `selectedSpeechModel`
/// persist independently of `selectedAssistantProvider` and
/// `selectedAssistantModel`. This is that independence made concrete: a
/// distinct type, with distinct storage keys, holding distinct identifier
/// types. Nothing in the app can write a speech selection through the code path
/// that writes an assistant selection, because the two do not share a type.
///
/// The test in section 114 restarts the settings store and asserts both
/// survive; the test in section 95 switches speech providers three times and
/// asserts the assistant selection never moved.
public struct SpeechSelection: Hashable, Sendable, Codable {
    public var providerID: SpeechToTextProviderID
    /// The provider's model, where it has a choice. Nil means "the provider
    /// decides", which is the normal case for Apple.
    public var modelID: SpeechModelIdentifier?
    /// The language to transcribe in. Nil follows the device.
    public var localeIdentifier: String?
    public var partialResultsEnabled: Bool

    public init(
        providerID: SpeechToTextProviderID = .apple,
        modelID: SpeechModelIdentifier? = nil,
        localeIdentifier: String? = nil,
        partialResultsEnabled: Bool = true
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.localeIdentifier = localeIdentifier
        self.partialResultsEnabled = partialResultsEnabled
    }

    /// Apple, following the device language.
    ///
    /// The right default for a first launch: it needs no download, no API key
    /// and no network, so voice input works before the user has configured
    /// anything at all.
    public static let `default` = SpeechSelection()

    public var locale: Locale? {
        localeIdentifier.map(Locale.init(identifier:))
    }

    /// The configuration to hand a provider.
    public func configuration() -> SpeechToTextConfiguration {
        SpeechToTextConfiguration(
            providerID: providerID,
            modelID: modelID,
            locale: locale,
            partialResultsEnabled: partialResultsEnabled
        )
    }

    // MARK: Storage

    /// Where the selection is kept.
    ///
    /// Deliberately *not* the keys the assistant provider uses. Two names, two
    /// values, no shared prefix that a future refactor could merge by accident.
    public enum StorageKey {
        public static let provider = "speech.provider"
        public static let model = "speech.model"
        public static let locale = "speech.locale"
        public static let partialResults = "speech.partialResults"
    }

    /// Reads a selection out of key-value storage.
    ///
    /// Missing values fall back to the default rather than failing: a first
    /// launch has none of these, and a build that adds a key later should not
    /// lose the ones already stored.
    public static func load(from defaults: any SpeechSettingsStore) -> SpeechSelection {
        var selection = SpeechSelection.default
        if let provider = defaults.string(forKey: StorageKey.provider), !provider.isEmpty {
            selection.providerID = SpeechToTextProviderID(provider)
        }
        if let model = defaults.string(forKey: StorageKey.model), !model.isEmpty {
            selection.modelID = SpeechModelIdentifier(model)
        }
        if let locale = defaults.string(forKey: StorageKey.locale), !locale.isEmpty {
            selection.localeIdentifier = locale
        }
        if let partials = defaults.bool(forKey: StorageKey.partialResults) {
            selection.partialResultsEnabled = partials
        }
        return selection
    }

    public func save(to defaults: any SpeechSettingsStore) {
        defaults.set(providerID.rawValue, forKey: StorageKey.provider)
        defaults.set(modelID?.rawValue, forKey: StorageKey.model)
        defaults.set(localeIdentifier, forKey: StorageKey.locale)
        defaults.set(partialResultsEnabled, forKey: StorageKey.partialResults)
    }
}

/// Key-value storage for the speech selection.
///
/// A protocol so the persistence test can restart a store without a real
/// `UserDefaults` suite, and so this target stays Foundation-only.
public protocol SpeechSettingsStore: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool?
    func set(_ value: String?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
}

/// An in-memory store whose contents survive being handed to a new reader.
///
/// What the persistence test uses: write through one instance, read through
/// another built from the same backing dictionary, which is what "restart the
/// repository" means without a filesystem.
public final class InMemorySpeechSettingsStore: SpeechSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    /// Everything written so far, for handing to a fresh instance.
    public var contents: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func bool(forKey key: String) -> Bool? {
        guard let raw = string(forKey: key) else { return nil }
        return raw == "true"
    }

    public func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func set(_ value: Bool, forKey key: String) {
        set(value ? "true" : "false", forKey: key)
    }
}
