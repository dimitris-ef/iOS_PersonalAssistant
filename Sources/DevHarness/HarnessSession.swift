import AIProviderApple
import AIProviderLocal
import AssistantAI
import AssistantDomain
import AssistantCore
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import DevSupport
import Foundation
import MockPlatform

/// One wired-up assistant, plus the printing that makes it legible in a terminal.
struct HarnessSession {
    let engine: AssistantEngine
    let registry: AIProviderRegistry
    let log: PlatformEventLog
    let conversationID: Conversation.ID
    let repositories: AssistantRepositories

    static func make(storageDirectory: URL?) async throws -> HarnessSession {
        let dateProvider = SystemDateProvider()

        let store: any SnapshotStore
        if let storageDirectory {
            store = JSONFileSnapshotStore(directory: storageDirectory)
        } else {
            store = EphemeralSnapshotStore()
        }
        let repositories = AssistantRepositories.snapshot(store: store)

        // Give the assistant something to reason with. In the app this comes
        // from onboarding.
        let existingProfile = try await repositories.profile.profile()
        if existingProfile.displayName == nil {
            var profile = existingProfile
            profile.displayName = "Dev User"
            profile.defaultPreparationDuration = TimeSpan.minutes(30)
            profile.defaultTravelDuration = TimeSpan.minutes(20)
            profile.wakeTime = TimeOfDay(hour: 7)
            profile.quietHours = DayWindow(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))
            try await repositories.profile.update(profile)
        }

        // Local AI, wired to the mock runtime and a throwaway models
        // directory. The harness is a terminal tool on a developer's machine:
        // it should be able to exercise the local-model *pipeline* without
        // downloading gigabytes or needing a GPU, and the mock runtime is
        // exactly that (section 89).
        // One runtime instance, shared by the manager and the provider — two
        // would mean the manager loading into one and the provider generating
        // from the other.
        let localRuntime = MockLocalModelRuntime()
        let localModels = LocalModelManager(
            catalog: LocalModelCatalog.bundled(),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: LocalModelStore.temporary(name: "dev-harness"),
            runtime: localRuntime,
            dateProvider: dateProvider
        )

        // Every provider is registered; only the scripted one is actually
        // usable here, and routing settles on it because the others report
        // themselves unavailable.
        let registry = AIProviderRegistry(providers: [
            AppleFoundationModelsProvider(),
            LocalModelProvider(manager: localModels, runtime: localRuntime),
            ScriptedDevProvider(dateProvider: dateProvider),
        ])

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = ScriptedDevProvider.providerID
        settings.routingPolicy = .preferOnDevice
        try await repositories.settings.update(settings)

        let log = PlatformEventLog()
        let services = PlatformServices.mock(log: log)

        let engine = AssistantEngine(
            providers: registry,
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )
        let conversation = try await engine.startConversation(title: "Dev session")

        return HarnessSession(
            engine: engine,
            registry: registry,
            log: log,
            conversationID: conversation.id,
            repositories: repositories
        )
    }

    // MARK: Modes

    func runInteractive() async throws {
        print(banner)
        print("Type a message, or \"quit\" to exit.\n")

        while true {
            print("you> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if ["quit", "exit", ":q"].contains(trimmed.lowercased()) { break }

            try await handle(trimmed)
        }
    }

    func runDemo() async throws {
        print(banner)
        for line in Self.demoScript {
            print("you> \(line)")
            try await handle(line)
        }
    }

    func printProviders() async {
        print("Registered AI providers:\n")
        for provider in await registry.allProviders() {
            let availability = await provider.availability()
            let status: String
            switch availability {
            case .available:
                status = "available"
            case .configurationRequired(let reason):
                status = "needs configuration — \(reason)"
            case .temporarilyUnavailable(let reason):
                status = "temporarily unavailable — \(reason)"
            case .unsupported(let reason):
                status = "unsupported — \(reason)"
            }
            print("  \(provider.metadata.id)")
            print("    \(provider.metadata.displayName)")
            print("    kind: \(provider.metadata.kind.rawValue), status: \(status)")
        }
    }

    // MARK: Turn printing

    private func handle(_ text: String) async throws {
        let result = try await engine.send(text, in: conversationID)

        print("\nAssistant response:")
        print("  \(result.assistantMessage.text)")

        if result.plan.actions.isEmpty {
            print("\nPlanned actions: none")
        } else {
            print("\nPlanned actions:")
            for action in result.plan.actions {
                let origin = action.origin == .supportPlanner ? " [support plan]" : ""
                print("  - \(action.request.summary)\(origin)")
            }
        }

        if !result.plan.rejected.isEmpty {
            print("\nRejected by validation:")
            for rejection in result.plan.rejected {
                print("  - \(rejection.name): \(rejection.error)")
            }
        }

        let entries = await log.drain()
        if entries.isEmpty {
            print("\nPlatform execution: nothing recorded")
        } else {
            print("\nPlatform execution (simulated — nothing reached a device):")
            for entry in entries {
                print("  - \(entry.formatted)")
            }
        }

        let applied = result.results.filter { toolResult in
            if case .executed = toolResult.outcome { return true }
            return false
        }
        if !applied.isEmpty {
            print("\nApplication state changes:")
            for item in applied {
                print("  - \(item.message)")
            }
        }

        let blocked = result.results.filter { !$0.outcome.didChangeAnything }
        if !blocked.isEmpty {
            print("\nNot executed:")
            for item in blocked {
                print("  - \(item.message)")
            }
        }

        print("")
    }

    private var banner: String {
        """
        ─────────────────────────────────────────────────────────────
        assistant-dev — core architecture harness
        Provider: scripted development rules (NOT a real model)
        Platform: mock services (NOTHING reaches a real iPhone)
        ─────────────────────────────────────────────────────────────
        """
    }

    private static let demoScript = [
        "Remember that I normally need 30 minutes to get ready",
        "I have a haircut next Sunday at 10 PM",
        "Remind me to pay the electricity bill sometime this week",
        "Make sure I actually wake up at 6:30 am",
        "What's coming up?",
    ]
}
