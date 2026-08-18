import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import MockPlatform
import PersonalMemory
import XCTest

/// Memory as the turn pipeline sees it.
///
/// `MemoryRankerTests` covers the policy; these cover what `ContextAssembler`
/// actually hands to a provider — the bounded, provider-neutral selection.
final class MemoryContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: ContextAssembler

    func testTheAssembledContextCarriesOnlyRelevantMemories() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let library = try await seedLibrary(into: repositories)

        let context = try await assembler(repositories).assemble(
            conversation: Conversation(createdAt: now),
            query: "I work tomorrow at 4 PM. When should I start getting ready and leave?",
            calendarEvents: []
        )

        let contents = context.relevantMemories.map(\.content)
        XCTAssertTrue(contents.contains(library.gettingReady.content), "\(contents)")
        XCTAssertTrue(contents.contains(library.commute.content), "\(contents)")
        XCTAssertFalse(contents.contains(library.camera.content))
        XCTAssertFalse(contents.contains(library.girlfriend.content))
    }

    func testTheAssembledContextIsBounded() async throws {
        let repositories = AssistantRepositories.ephemeral()
        // Twenty relevant memories, far more than any prompt should carry.
        for index in 0..<20 {
            try await repositories.memories.store(
                MemoryItem(
                    kind: .routine,
                    content: "Work routine \(index): I leave for work in the morning",
                    salience: 0.7,
                    createdAt: now,
                    source: .user
                )
            )
        }

        let context = try await assembler(repositories).assemble(
            conversation: Conversation(createdAt: now),
            query: "when do I leave for work",
            calendarEvents: []
        )

        XCTAssertLessThanOrEqual(
            context.relevantMemories.count,
            MemoryRelevancePolicy.default.maximumMemories
        )
        XCTAssertFalse(context.relevantMemories.isEmpty)
    }

    func testAnIrrelevantRequestCarriesNoMemories() async throws {
        let repositories = AssistantRepositories.ephemeral()
        _ = try await seedLibrary(into: repositories)

        let context = try await assembler(repositories).assemble(
            conversation: Conversation(createdAt: now),
            query: "What is the capital of Peru?",
            calendarEvents: []
        )

        XCTAssertTrue(
            context.relevantMemories.isEmpty,
            "unrelated memories reached the prompt: \(context.relevantMemories.map(\.content))"
        )
    }

    func testAnEmptyMemoryStoreAssemblesNormally() async throws {
        let repositories = AssistantRepositories.ephemeral()

        let context = try await assembler(repositories).assemble(
            conversation: Conversation(createdAt: now),
            query: "when do I leave for work",
            calendarEvents: []
        )

        XCTAssertTrue(context.relevantMemories.isEmpty)
    }

    // MARK: The prompt

    func testTheMemorySectionIsOmittedEntirelyWhenNothingIsRelevant() {
        let section = MemoryContextFormatter().section(for: [])
        // Not "no memories found" — a sentence about the absence of history is
        // something for the model to remark on.
        XCTAssertNil(section)
    }

    /// Confidence and identifiers are application concerns.
    func testTheRenderedSectionLeaksNoMetadata() {
        let memory = MemoryItem(
            kind: .routine,
            content: "I need 45 minutes to get ready for work",
            salience: 0.83,
            createdAt: now,
            source: .assistant,
            confidence: 0.72
        )

        let section = MemoryContextFormatter().section(for: [memory]) ?? ""

        XCTAssertTrue(section.contains("I need 45 minutes to get ready for work"))
        XCTAssertTrue(section.contains("Routine"), "the category is useful to the model")
        XCTAssertFalse(section.contains("0.72"), "confidence is not the model's business")
        XCTAssertFalse(section.contains("0.83"))
        XCTAssertFalse(section.contains(memory.id.description), "no identifiers in prompts")
        XCTAssertFalse(section.contains("assistant"), "no source metadata in prompts")
    }

    func testTheSystemPromptCarriesTheSelectedMemories() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let library = try await seedLibrary(into: repositories)

        let context = try await assembler(repositories).assemble(
            conversation: Conversation(createdAt: now),
            query: "when should I start getting ready for work",
            calendarEvents: []
        )
        let prompt = SystemPromptBuilder().systemPrompt(for: context)

        XCTAssertTrue(prompt.contains(library.gettingReady.content))
        XCTAssertFalse(prompt.contains(library.camera.content))
    }

    // MARK: Provider independence

    /// Retrieval belongs to the application. Changing model changes nothing
    /// about what the assistant recalls.
    func testSwitchingProviderChangesNeitherMemoriesNorTheirSelection() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let library = try await seedLibrary(into: repositories)
        let assembler = assembler(repositories)

        var selections: [[MemoryItem.ID]] = []
        for provider: AIProviderIdentifier in ["remote.openai-compatible", "apple.foundation-models", "dev.scripted"] {
            var settings = try await repositories.settings.settings()
            settings.preferredProviderID = provider
            try await repositories.settings.update(settings)

            let context = try await assembler.assemble(
                conversation: Conversation(createdAt: now),
                query: "when should I leave for work",
                calendarEvents: []
            )
            selections.append(context.relevantMemories.map(\.id))
        }

        XCTAssertEqual(selections[0], selections[1])
        XCTAssertEqual(selections[1], selections[2])

        // And nothing was lost, reset or reclassified along the way.
        let all = try await repositories.memories.all()
        XCTAssertEqual(all.count, library.all.count)
        XCTAssertEqual(
            Set(all.map(\.confidence)),
            Set(library.all.map(\.confidence))
        )
    }

    /// No credential, no network, no provider — retrieval still works. This is
    /// what makes memory usable with the Apple and local providers, and in CI.
    func testRetrievalNeedsNoProviderAtAll() async throws {
        let repositories = AssistantRepositories.ephemeral()
        _ = try await seedLibrary(into: repositories)

        let selected = try await MemoryRetrievalService(repository: repositories.memories)
            .relevantMemories(for: "how long is my commute", now: now)

        XCTAssertFalse(selected.isEmpty)
    }

    // MARK: Helpers

    private func assembler(_ repositories: AssistantRepositories) -> ContextAssembler {
        ContextAssembler(
            repositories: repositories,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    @discardableResult
    private func seedLibrary(
        into repositories: AssistantRepositories
    ) async throws -> ContextMemoryLibrary {
        let library = ContextMemoryLibrary(now: now)
        for memory in library.all {
            try await repositories.memories.store(memory)
        }
        return library
    }
}

/// The memory set from the milestone's behavioural example.
struct ContextMemoryLibrary {
    let gettingReady: MemoryItem
    let commute: MemoryItem
    let reminderPreference: MemoryItem
    let girlfriend: MemoryItem
    let camera: MemoryItem
    let groceries: MemoryItem

    var all: [MemoryItem] {
        [gettingReady, commute, reminderPreference, girlfriend, camera, groceries]
    }

    init(now: Date) {
        gettingReady = MemoryItem(
            kind: .routine,
            content: "I usually need 45 minutes to get ready for work",
            salience: 0.8,
            createdAt: now.addingTimeInterval(-TimeSpan.days(30)),
            source: .user
        )
        commute = MemoryItem(
            kind: .place,
            content: "Work is normally 30 minutes from home",
            salience: 0.8,
            createdAt: now.addingTimeInterval(-TimeSpan.days(60)),
            source: .user
        )
        reminderPreference = MemoryItem(
            kind: .preference,
            content: "I prefer important reminders to repeat until I confirm completion",
            salience: 0.7,
            createdAt: now.addingTimeInterval(-TimeSpan.days(10)),
            source: .user
        )
        girlfriend = MemoryItem(
            kind: .person,
            content: "My girlfriend's name is Anna",
            salience: 0.6,
            createdAt: now.addingTimeInterval(-TimeSpan.days(90)),
            source: .user
        )
        camera = MemoryItem(
            kind: .preference,
            content: "I like Sony cameras",
            salience: 0.3,
            createdAt: now.addingTimeInterval(-TimeSpan.days(5)),
            source: .user
        )
        groceries = MemoryItem(
            kind: .recurringCommitment,
            content: "I normally buy groceries on Saturday",
            salience: 0.5,
            createdAt: now.addingTimeInterval(-TimeSpan.days(20)),
            source: .user
        )
    }
}
