import AIProviderApple
import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import DevSupport
import ExecutiveSupport
import MockPlatform
import XCTest

/// Switching to and from the Apple provider, and what must survive it.
///
/// The claim the Settings screen makes to the user is that their conversations,
/// tasks and memory belong to the app rather than to the model. This is that
/// claim as a test: the provider is a field in settings, and changing it moves
/// nothing.
///
/// Nothing here needs Apple Intelligence, a supported device or an Apple SDK.
/// That is deliberate — the property is about the *architecture*, and it should
/// hold on a Linux CI runner exactly as it does on a phone.
final class AppleProviderSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeRepositories() async throws -> AssistantRepositories {
        let repositories = AssistantRepositories.ephemeral()

        try await repositories.memories.store(
            MemoryItem(
                kind: .place,
                content: "Work is normally 30 minutes from home",
                salience: 0.8,
                createdAt: now,
                source: .user
            )
        )
        try await repositories.memories.store(
            MemoryItem(
                kind: .preference,
                content: "I like Sony cameras",
                salience: 0.3,
                createdAt: now,
                source: .user
            )
        )
        try await repositories.tasks.save(
            TaskItem(
                title: "Renew the passport",
                status: .reminded,
                timing: .fixed(now.addingTimeInterval(TimeSpan.days(3))),
                createdAt: now
            )
        )
        return repositories
    }

    /// A snapshot of everything that must not move.
    private struct StoredState: Equatable {
        var memories: [String]
        var memoryConfidences: [Double]
        var taskTitles: [String]
        var taskStatuses: [TaskStatus]
        var conversationMessages: [String]
    }

    private func snapshot(_ repositories: AssistantRepositories) async throws -> StoredState {
        let memories = try await repositories.memories.all().sorted { $0.content < $1.content }
        let tasks = try await repositories.tasks.tasks(matching: TaskFilter())
            .sorted { $0.title < $1.title }
        let conversations = try await repositories.conversations.allConversations()
        return StoredState(
            memories: memories.map(\.content),
            memoryConfidences: memories.map(\.confidence),
            taskTitles: tasks.map(\.title),
            taskStatuses: tasks.map(\.status),
            conversationMessages: conversations.flatMap { $0.messages.map(\.text) }
        )
    }

    private func select(
        _ providerID: AIProviderIdentifier,
        in repositories: AssistantRepositories
    ) async throws {
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = providerID
        try await repositories.settings.update(settings)
    }

    // MARK: The guarantee

    func testSwitchingToAppleAndBackMovesNothing() async throws {
        let repositories = try await makeRepositories()
        let before = try await snapshot(repositories)

        try await select(ScriptedDevProvider.providerID, in: repositories)
        let afterScripted = try await snapshot(repositories)

        try await select(AppleFoundationModelsProvider.providerID, in: repositories)
        let afterApple = try await snapshot(repositories)

        try await select(ScriptedDevProvider.providerID, in: repositories)
        let afterSwitchingBack = try await snapshot(repositories)

        XCTAssertEqual(before, afterScripted)
        XCTAssertEqual(before, afterApple, "selecting the Apple provider changed stored data")
        XCTAssertEqual(before, afterSwitchingBack, "switching away changed stored data")
    }

    /// Selecting a provider that cannot run is allowed. It is a stored
    /// preference, not an assertion that the model is ready — the user may be
    /// about to turn Apple Intelligence on.
    func testTheChoiceIsRememberedEvenWhileTheModelIsUnavailable() async throws {
        let repositories = try await makeRepositories()
        let apple = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.appleIntelligenceNotEnabled)
        )

        try await select(AppleFoundationModelsProvider.providerID, in: repositories)

        let settings = try await repositories.settings.settings()
        XCTAssertEqual(settings.preferredProviderID, AppleFoundationModelsProvider.providerID)
        let availability = await apple.availability()
        XCTAssertFalse(availability.isAvailable)
    }

    /// A conversation started under one provider continues under another. The
    /// Apple session is rebuilt from this history rather than replacing it, so
    /// there is nothing to migrate.
    func testAConversationSurvivesTheSwitch() async throws {
        let repositories = try await makeRepositories()
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [
                ScriptedDevProvider(dateProvider: FixedDateProvider(now: now)),
                AppleFoundationModelsProvider(
                    availabilityReader: FixedAppleModelAvailabilityReader(.deviceNotEligible)
                ),
            ]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )

        try await select(ScriptedDevProvider.providerID, in: repositories)
        let conversation = try await engine.startConversation(title: "Morning")
        _ = try await engine.send("remind me to call the dentist tomorrow at 10", in: conversation.id)

        let afterFirstTurn = try await snapshot(repositories)
        XCTAssertFalse(afterFirstTurn.conversationMessages.isEmpty)

        try await select(AppleFoundationModelsProvider.providerID, in: repositories)

        let afterSwitch = try await snapshot(repositories)
        XCTAssertEqual(afterFirstTurn, afterSwitch)
    }

    /// §47: choosing the on-device model must not quietly become a cloud
    /// request. When Apple is selected and unavailable, routing under the
    /// explicit policy fails rather than substituting another provider.
    func testAnUnavailableAppleProviderIsNotSilentlySwappedForAnother() async throws {
        let repositories = try await makeRepositories()
        let registry = AIProviderRegistry(providers: [
            AppleFoundationModelsProvider(
                availabilityReader: FixedAppleModelAvailabilityReader(.deviceNotEligible)
            ),
            ScriptedDevProvider(dateProvider: FixedDateProvider(now: now)),
        ])

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = AppleFoundationModelsProvider.providerID
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        do {
            _ = try await ModelRouter().selectProvider(from: registry, settings: settings)
            XCTFail("An explicitly chosen on-device provider must not be silently replaced")
        } catch let error as ModelRoutingError {
            guard case .explicitProviderUnavailable(let id, _) = error else {
                return XCTFail("Expected .explicitProviderUnavailable, got \(error)")
            }
            XCTAssertEqual(id, AppleFoundationModelsProvider.providerID)
        }
    }
}
