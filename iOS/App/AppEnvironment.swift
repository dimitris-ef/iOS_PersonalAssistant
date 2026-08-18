import AIProviderApple
import AIProviderLocal
import AIProviderRemote
import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
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
    /// What this launch is: production, or a seeded preview/CI run.
    let launch: AppLaunchConfiguration
    /// Writing memories: defaults, duplicate detection, conflict resolution.
    /// The same service the assistant's `storeMemory` tool uses, so a memory
    /// the user types and one the assistant saves cannot diverge.
    let memory: MemoryService

    /// The provider the remote configuration belongs to.
    static let remoteProviderID: AIProviderIdentifier = "remote.openai-compatible"

    init(
        engine: AssistantEngine,
        repositories: AssistantRepositories,
        services: PlatformServices,
        providers: AIProviderRegistry,
        dateProvider: any DateProvider,
        credentialStore: any CredentialStore,
        remoteConfiguration: RemoteAIConfigurationStore,
        launch: AppLaunchConfiguration,
        memory: MemoryService
    ) {
        self.engine = engine
        self.repositories = repositories
        self.services = services
        self.providers = providers
        self.dateProvider = dateProvider
        self.credentialStore = credentialStore
        self.remoteConfiguration = remoteConfiguration
        self.launch = launch
        self.memory = memory
    }

    /// The environment the app actually launches with.
    ///
    /// Storage is SwiftData, on disk, in the app's own container. Everything
    /// the user creates — conversations, tasks, memories, reminder plans,
    /// settings, profile — is still there next launch.
    ///
    /// Throws if the store cannot be opened, and does **not** quietly fall back
    /// to in-memory repositories. A fallback would produce an app that looks
    /// completely healthy while silently discarding everything at termination,
    /// which is a worse outcome than refusing to start. `PersonalAssistantApp`
    /// catches this and says so.
    @MainActor
    static func makePersistent(
        configuration: AppLaunchConfiguration = .current()
    ) throws -> AppEnvironment {
        let container = try AssistantPersistenceContainer.make(location: configuration.persistence)
        let repositories = AssistantRepositories.persistent(container: container)
        return make(repositories: repositories, launch: configuration)
    }

    /// In-memory repositories and mock services, for previews and tests.
    ///
    /// Still `ephemeral()`, and deliberately so: a preview should start from a
    /// clean, predictable store every time and must never write into the store
    /// a real launch would open.
    ///
    /// - Platform services are mocks. They record intent in memory and report
    ///   `.simulated`, so nothing in the UI can claim an event, alarm or
    ///   notification reached the operating system. **This stays true even when
    ///   a real model is connected**: the remote model proposes actions, and
    ///   they still execute against mocks.
    /// - Four providers are registered. Apple's and the local one report
    ///   themselves unsupported. The remote one becomes usable as soon as it has
    ///   an endpoint, a key and a model. `ScriptedDevProvider` is the fallback
    ///   that keeps the app working — and CI green — with no credentials at all.
    ///
    /// TODO-XCODE: replace the platform services with the real Apple ones. The
    /// UI does not change when that happens.
    @MainActor
    static func makeDemo() -> AppEnvironment {
        make(
            repositories: AssistantRepositories.ephemeral(),
            // Previews want content to render. Because the store is ephemeral,
            // seeding it cannot reach anything a real launch would open.
            launch: AppLaunchConfiguration(persistence: .inMemory, seedsDemoData: true)
        )
    }

    /// Everything except the choice of storage.
    ///
    /// The providers, the engine, the credential store and the platform
    /// services are identical whichever repositories are passed in — which is
    /// the whole claim the repository abstraction makes, stated as code.
    @MainActor
    private static func make(
        repositories: AssistantRepositories,
        launch: AppLaunchConfiguration
    ) -> AppEnvironment {
        let dateProvider = SystemDateProvider()
        let services = PlatformServices.mock()

        // TODO-XCODE: `KeychainCredentialStore` has not been verified against a
        // real Keychain. If it misbehaves, the app still runs — a failed read
        // reads as "no credential", which shows as "Setup needed".
        //
        // Note what is *not* in the paragraph above: SwiftData. The API key
        // lives here, in the Keychain, and never enters the database. The store
        // holds the provider's identifier and nothing that could authenticate
        // as anyone.
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
            remoteConfiguration: remoteConfiguration,
            launch: launch,
            memory: MemoryService(
                repository: repositories.memories,
                dateProvider: dateProvider
            )
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
