import AIProviderApple
import AIProviderLocal
import AIProviderRemote
import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import DevSupport
import Foundation
import MockPlatform

/// The composition root: the one place concrete implementations are chosen.
///
/// The UI never constructs a repository, a platform service or a provider. It
/// receives this, so moving from mock services to real Apple frameworks is a
/// change here and nowhere else.
///
/// Nothing in this type is Apple-specific yet — every service is a mock, and
/// every service says so through `PlatformFidelity`.
final class AppEnvironment: Sendable {
    let engine: AssistantEngine
    let repositories: AssistantRepositories
    let services: PlatformServices
    let providers: AIProviderRegistry
    let dateProvider: any DateProvider

    init(
        engine: AssistantEngine,
        repositories: AssistantRepositories,
        services: PlatformServices,
        providers: AIProviderRegistry,
        dateProvider: any DateProvider
    ) {
        self.engine = engine
        self.repositories = repositories
        self.services = services
        self.providers = providers
        self.dateProvider = dateProvider
    }

    /// The configuration used while the Apple layer does not exist.
    ///
    /// - Platform services are mocks. They record intent in memory and report
    ///   `.simulated`, so nothing in the UI can claim an event, alarm or
    ///   notification reached the operating system.
    /// - Storage is in-memory. Nothing survives relaunch yet.
    /// - The assistant is driven by `ScriptedDevProvider`, a deterministic
    ///   rule-based stand-in. It is **not a model**. It exists so the real
    ///   pipeline — tool decoding, authorization, reminder planning,
    ///   execution — runs end to end behind the UI.
    ///
    /// TODO-XCODE: replace with `makeLive()` once EventKit, UserNotifications,
    /// AlarmKit and a real `AIProvider` implementation exist. The UI does not
    /// change when that happens.
    ///
    /// Deliberately not actor-isolated: it is called from the app's `init`, and
    /// nothing it builds requires the main actor.
    static func makeDemo() -> AppEnvironment {
        let dateProvider = SystemDateProvider()
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()

        let providers = AIProviderRegistry(providers: [
            AppleFoundationModelsProvider(),
            LocalModelProvider(),
            RemoteAIProvider(adapter: UnconfiguredCloudAdapter()),
            ScriptedDevProvider(dateProvider: dateProvider),
        ])

        let engine = AssistantEngine(
            providers: providers,
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )

        return AppEnvironment(
            engine: engine,
            repositories: repositories,
            services: services,
            providers: providers,
            dateProvider: dateProvider
        )
    }

    /// The providers the model selector offers, in display order.
    ///
    /// Availability is read from each provider rather than assumed, so the
    /// selector shows the truth: none of the three can serve a request yet.
    func providerOptions() async -> [ProviderOption] {
        var options: [ProviderOption] = []
        for provider in await providers.allProviders() {
            // The scripted stand-in is a development detail, not a model the
            // user should be offered.
            guard provider.metadata.kind != .development else { continue }
            let availability = await provider.availability()
            options.append(
                ProviderOption(
                    id: provider.metadata.id,
                    metadata: provider.metadata,
                    availability: availability
                )
            )
        }
        return options
    }
}

/// A provider as the settings UI needs to show it.
struct ProviderOption: Identifiable, Sendable {
    let id: AIProviderIdentifier
    let metadata: AIProviderMetadata
    let availability: AIProviderAvailability

    var isAvailable: Bool { availability.isAvailable }

    var unavailableReason: String? {
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }
}
