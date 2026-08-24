import Foundation

/// The transcription engines this build has.
///
/// ## Why this is not `AIProviderRegistry`
///
/// Section 4. They would have had the same shape — a dictionary keyed by an
/// identifier, with a selection — and merging them would have been the obvious
/// saving. It is the wrong saving. One registry would mean one selection, and
/// the entire premise of this milestone is that "who transcribes" and "who
/// reasons" are two independent choices; a shared registry makes the
/// independence a convention that some future call site can break, rather than
/// a fact about the program.
///
/// The concrete failure it prevents: a speech model appearing in the assistant
/// model picker because both lists came from the same place. Section 4 forbids
/// it, and this is the structure that makes it impossible rather than merely
/// forbidden — `SpeechToTextProvider` and `AIProvider` share no supertype, so
/// neither registry can hold the other's members.
public struct SpeechToTextProviderRegistry: Sendable {
    private let providers: [SpeechToTextProviderID: any SpeechToTextProvider]
    /// The order the UI lists them in. Stable, not dictionary order.
    public let order: [SpeechToTextProviderID]

    public init(providers: [any SpeechToTextProvider]) {
        var table: [SpeechToTextProviderID: any SpeechToTextProvider] = [:]
        var order: [SpeechToTextProviderID] = []
        for provider in providers where table[provider.id] == nil {
            table[provider.id] = provider
            order.append(provider.id)
        }
        self.providers = table
        self.order = order
    }

    public var isEmpty: Bool { providers.isEmpty }

    public func provider(for id: SpeechToTextProviderID) -> (any SpeechToTextProvider)? {
        providers[id]
    }

    public func contains(_ id: SpeechToTextProviderID) -> Bool {
        providers[id] != nil
    }

    public var all: [any SpeechToTextProvider] {
        order.compactMap { providers[$0] }
    }

    /// The provider to use for a configuration, or nil when this build has none.
    ///
    /// Returns nil rather than substituting a different engine. Section 41 is
    /// the reason and it is not a small one: if "the selected provider is
    /// missing" silently resolved to whichever provider happened to be first,
    /// a build where the local runtime failed to link would quietly start
    /// uploading the user's audio to OpenAI. Falling back is a decision only
    /// the person speaking gets to make.
    public func resolve(_ configuration: SpeechToTextConfiguration)
        -> (any SpeechToTextProvider)?
    {
        providers[configuration.providerID]
    }

    /// Availability for every registered provider, for the Settings list.
    ///
    /// Asked concurrently: three providers each doing an authorization check
    /// and a filesystem probe should take as long as the slowest, not as long
    /// as all three.
    public func availabilities(
        for configuration: SpeechToTextConfiguration
    ) async -> [SpeechToTextProviderID: SpeechToTextAvailability] {
        await withTaskGroup(
            of: (SpeechToTextProviderID, SpeechToTextAvailability).self
        ) { group in
            for provider in all {
                group.addTask {
                    var configuration = configuration
                    configuration.providerID = provider.id
                    return (provider.id, await provider.availability(for: configuration))
                }
            }
            var result: [SpeechToTextProviderID: SpeechToTextAvailability] = [:]
            for await (id, availability) in group {
                result[id] = availability
            }
            return result
        }
    }
}
