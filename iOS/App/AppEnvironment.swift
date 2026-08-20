import AIProviderApple
import AIProviderLocal
import AIProviderRemote
import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import AssistantPlatform
import AssistantPlatformApple
import AssistantVoice
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
    /// The notification delegate, when this launch has real notifications.
    ///
    /// Held here because iOS's `delegate` property is weak: nothing else in the
    /// app retains this object, and if it is released the user's "Done" button
    /// stops reaching the task lifecycle — silently, with no error anywhere.
    ///
    /// `nil` on a demo launch, where notifications are mocks.
    let notificationCoordinator: AppleNotificationCoordinator?
    /// The bridge system surfaces use: Siri, Shortcuts, the Action Button.
    ///
    /// Built here so an App Intent and the app share one composition — the
    /// same repositories, the same providers, the same database. See
    /// `AppIntentDependencies`.
    let commands: AssistantCommandService
    /// Speech recognition and synthesis.
    ///
    /// Always present — on a platform without the Speech framework the input
    /// service reports `unsupported` rather than being absent, so the
    /// microphone button can be shown disabled with a reason instead of
    /// vanishing.
    let voice: VoiceServices?

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
        memory: MemoryService,
        notificationCoordinator: AppleNotificationCoordinator?,
        voice: VoiceServices?,
        commands: AssistantCommandService
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
        self.notificationCoordinator = notificationCoordinator
        self.voice = voice
        self.commands = commands
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

        // The one line that decides whether this app changes the user's phone.
        //
        // A seeded launch gets mocks — always, and not merely as a convenience.
        // Demo seeding writes example appointments, and a seeder pointed at
        // `EventKit` would put a fabricated haircut in someone's real calendar,
        // where it would sync to their other devices and outlive the app. The
        // only launches that seed are CI screenshots, SwiftUI previews and a
        // developer's debug build, and none of them should be able to reach the
        // operating system at all.
        //
        // Everything else gets the real thing: EventKit, UserNotifications and
        // AlarmKit where the device has it. The UI above did not change to make
        // this possible, which was the point of the platform protocols.
        let platform: AppleLivePlatform? = launch.seedsDemoData ? nil : PlatformServices.live()
        let services = platform?.services ?? PlatformServices.mock()

        // Voice follows the same rule as the platform services, for the same
        // reason: a seeded launch is a demonstration, and CI screenshot runs
        // have no microphone. The mock renders the voice UI without ever
        // opening an audio session.
        let voice = launch.seedsDemoData ? VoiceServices.mock() : VoiceServices.live()

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

        let memory = MemoryService(
            repository: repositories.memories,
            dateProvider: dateProvider
        )

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
            memory: memory,
            notificationCoordinator: platform?.notifications,
            voice: voice,
            commands: AssistantCommandService(
                engine: engine,
                repositories: repositories,
                memory: memory,
                dateProvider: dateProvider
            )
        )
    }

    /// Connects notification responses to the task lifecycle.
    ///
    /// Called once, after the repositories are open. Everything a notification
    /// response can do goes through `FollowUpService` — the same door the UI's
    /// own Done and Snooze buttons use — so the rule that a dismissal is not a
    /// completion is enforced in one place and cannot be routed around by
    /// adding a button to a notification.
    ///
    /// `onOpen` is called when the user taps the notification rather than
    /// answering it. Nothing is recorded in that case: opening the app is not a
    /// claim about the task.
    func connectNotificationRouting(
        onOpen: @escaping @Sendable (TaskItem.ID) async -> Void,
        onChange: @escaping @Sendable () async -> Void
    ) {
        guard let notificationCoordinator else { return }

        notificationCoordinator.setHandler { [engine] route in
            switch route {
            case .outcome(let outcome, let taskID, let stageID):
                do {
                    try await engine.followUp.handle(
                        outcome: outcome,
                        forTask: taskID,
                        stageID: stageID
                    )
                    await onChange()
                } catch {
                    // Nothing is logged from the error itself: it can carry a
                    // task title. A response that cannot be applied — the task
                    // was deleted, the store is unavailable — leaves the
                    // lifecycle untouched, which reconciliation corrects on the
                    // next foreground.
                }

            case .open(let taskID, _):
                await onOpen(taskID)

            case .ignored:
                break
            }
        }
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
        // Not "not available yet": a device that cannot run Apple
        // Intelligence is not waiting for anything. The reason line underneath
        // says which kind of unavailable this is.
        case .unsupported: return "Not available"
        }
    }
}
