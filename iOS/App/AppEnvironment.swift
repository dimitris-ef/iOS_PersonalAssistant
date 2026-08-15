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
final class AppEnvironment: Sendable {
    let engine: AssistantEngine
    let repositories: AssistantRepositories
    let services: PlatformServices
    let providers: AIProviderRegistry
    let dateProvider: any DateProvider

    /// Secure storage for the remote provider's API key.
    let credentialStore: any CredentialStore
    /// Endpoint and model for the remote provider. Not secret.
    let remoteConfiguration: RemoteAIConfigurationStore

    /// The provider the remote configuration belongs to.
    static let remoteProviderID: AIProviderIdentifier = "remote.openai-compatible"

    init(
        engine: AssistantEngine,
        repositories: AssistantRepositories,
        services: PlatformServices,
        providers: AIProviderRegistry,
        dateProvider: any DateProvider,
        credentialStore: any CredentialStore,
        remoteConfiguration: RemoteAIConfigurationStore
    ) {
        self.engine = engine
        self.repositories = repositories
        self.services = services
        self.providers = providers
        self.dateProvider = dateProvider
        self.credentialStore = credentialStore
        self.remoteConfiguration = remoteConfiguration
    }

    /// The configuration used while the Apple layer does not exist.
    ///
    /// - Platform services are mocks. They record intent in memory and report
    ///   `.simulated`, so nothing in the UI can claim an event, alarm or
    ///   notification reached the operating system. **This stays true even when
    ///   a real model is connected**: the remote model proposes actions, and
    ///   they still execute against mocks.
    /// - Storage is in-memory. Nothing survives relaunch yet.
    /// - Four providers are registered. Apple's and the local one report
    ///   themselves unsupported. The remote one becomes usable as soon as it has
    ///   an endpoint, a key and a model. `ScriptedDevProvider` is the fallback
    ///   that keeps the app working — and CI green — with no credentials at all.
    ///
    /// TODO-XCODE: replace the platform services with the real Apple ones. The
    /// UI does not change when that happens.
    @MainActor
    static func makeDemo() -> AppEnvironment {
        let dateProvider = SystemDateProvider()
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()

        // TODO-XCODE: `KeychainCredentialStore` has not been verified against a
        // real Keychain. If it misbehaves, the app still runs — a failed read
        // reads as "no credential", which shows as "Setup needed".
        let credentialStore: any CredentialStore = KeychainCredentialStore()
        let remoteConfiguration = RemoteAIConfigurationStore()

        let remoteProvider = RemoteAIProvider(
            adapter: OpenAICompatibleAdapter(
                providerID: remoteProviderID,
                displayName: "Cloud Model"
            ),
            configuration: remoteConfiguration,
            // Priority: what the user saved, then a development xcconfig.
            // Never the other way round — a local file must not silently
            // override a key someone typed into Settings.
            credentials: ChainedCredentialProvider([
                CredentialStoreProvider(store: credentialStore),
                DevelopmentSecretsCredentialProvider(),
            ]),
            logger: ConsoleRemoteAILogger()
        )

        let providers = AIProviderRegistry(providers: [
            AppleFoundationModelsProvider(),
            LocalModelProvider(),
            remoteProvider,
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
            dateProvider: dateProvider,
            credentialStore: credentialStore,
            remoteConfiguration: remoteConfiguration
        )
    }

    /// The providers the model selector offers, in display order.
    ///
    /// Availability is read from each provider rather than assumed, so the
    /// selector shows the truth rather than "this type exists in the binary".
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

    // MARK: Remote credentials

    /// Whether a key is stored. Deliberately returns a flag, not the key —
    /// nothing in the UI needs the value, only whether one exists.
    func hasRemoteAPIKey() async -> Bool {
        do {
            let value = try await credentialStore.credential(
                for: .remoteAIAPIKey(providerID: Self.remoteProviderID)
            )
            return value?.isEmpty == false
        } catch {
            return false
        }
    }

    func setRemoteAPIKey(_ key: String?) async throws {
        try await credentialStore.setCredential(
            key,
            for: .remoteAIAPIKey(providerID: Self.remoteProviderID)
        )
    }
}

/// A provider as the settings UI needs to show it.
struct ProviderOption: Identifiable, Sendable {
    let id: AIProviderIdentifier
    let metadata: AIProviderMetadata
    let availability: AIProviderAvailability

    var isAvailable: Bool { availability.isAvailable }

    var unavailableReason: String? { availability.reason }

    /// True when the user can fix it from Settings, as opposed to it being
    /// unimplemented on this build.
    var needsConfiguration: Bool { availability.isUserResolvable }

    /// The short state shown next to the provider's name.
    var statusLabel: String {
        switch availability {
        case .available: return "Ready"
        case .configurationRequired: return "Setup needed"
        case .temporarilyUnavailable: return "Unavailable"
        case .unsupported: return "Not available yet"
        }
    }
}
