#if canImport(FoundationModels)

import AssistantAI
import AssistantDomain
import AssistantPlatform
import AssistantTools
import FoundationModels
import MockPlatform
import XCTest
@testable import AIProviderApple

/// What happens when Apple's model asks to use a tool.
///
/// The property being defended is narrow and important: the adapter turns a
/// model's request into a *proposal* and nothing else. Everything that changes
/// the user's world happens later, in `AssistantEngine`, behind the validation
/// and authorization every provider goes through.
@available(iOS 26.0, macOS 26.0, *)
final class AppleToolAdapterTests: XCTestCase {

    // MARK: Helpers

    private func schema(for kind: ToolKind) -> AIToolSchema {
        let specification = ToolCatalog.specification(for: kind)
        return AIToolSchema(
            name: specification.name,
            description: specification.summary,
            parameters: specification.parameters
        )
    }

    private func adapter(
        for kind: ToolKind,
        collector: AppleFoundationToolCollector
    ) throws -> AppleFoundationToolAdapter {
        let tool = schema(for: kind)
        return AppleFoundationToolAdapter(
            name: tool.name,
            description: tool.description,
            parameters: try AppleGenerationSchemaBridge.generationSchema(for: tool),
            collector: collector
        )
    }

    // MARK: Arguments become AIToolCalls

    func testCreateTaskArgumentsBecomeAToolCall() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        _ = try await tool.call(
            arguments: GeneratedContent(json: #"{"title":"Renew the passport","importance":"high"}"#)
        )

        let calls = await collector.drain()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, ToolKind.createTask.rawValue)
        XCTAssertEqual(calls.first?.arguments["title"]?.stringValue, "Renew the passport")
        XCTAssertEqual(calls.first?.arguments["importance"]?.stringValue, "high")
    }

    func testCreateReminderArgumentsBecomeAToolCall() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createReminder, collector: collector)

        _ = try await tool.call(
            arguments: GeneratedContent(
                json: #"{"title":"Call the dentist","dueDate":"2026-03-14T10:00:00Z"}"#
            )
        )

        let calls = await collector.drain()
        XCTAssertEqual(calls.first?.name, ToolKind.createReminder.rawValue)
        XCTAssertEqual(calls.first?.arguments["title"]?.stringValue, "Call the dentist")
        XCTAssertEqual(calls.first?.arguments["dueDate"]?.stringValue, "2026-03-14T10:00:00Z")
    }

    func testStoreMemoryArgumentsBecomeAToolCall() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .storeMemory, collector: collector)

        _ = try await tool.call(
            arguments: GeneratedContent(
                json: #"{"kind":"routine","content":"Needs 45 minutes to get ready"}"#
            )
        )

        let calls = await collector.drain()
        XCTAssertEqual(calls.first?.name, ToolKind.storeMemory.rawValue)
        XCTAssertEqual(
            calls.first?.arguments["content"]?.stringValue,
            "Needs 45 minutes to get ready"
        )
    }

    /// Every call gets an identifier, and no two share one — the engine pairs
    /// results back to calls by it, so a collision would attach one action's
    /// outcome to another.
    func testEveryProposedCallGetsItsOwnIdentifier() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        _ = try await tool.call(arguments: GeneratedContent(json: #"{"title":"One"}"#))
        _ = try await tool.call(arguments: GeneratedContent(json: #"{"title":"Two"}"#))

        let calls = await collector.drain()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(calls[0].id, calls[1].id)
    }

    // MARK: The safety property

    /// The whole point of the adapter. Calling it must not touch the platform.
    func testCallingTheAdapterDoesNotTouchThePlatform() async throws {
        let log = PlatformEventLog()
        // Real mock services, wired to a log that records anything they are
        // asked to do. If the adapter reached the platform, this would notice.
        _ = MockPermissionService.mock(log: log)

        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createReminder, collector: collector)

        _ = try await tool.call(
            arguments: GeneratedContent(
                json: #"{"title":"Call the dentist","dueDate":"2026-03-14T10:00:00Z"}"#
            )
        )

        let entries = await log.allEntries()
        XCTAssertTrue(
            entries.isEmpty,
            "the tool adapter reached the platform: \(entries.map(\.formatted))"
        )

        // And it did produce the proposal, so the emptiness above is not
        // because nothing happened at all.
        let calls = await collector.drain()
        XCTAssertEqual(calls.count, 1)
    }

    /// The model keeps reasoning after a tool returns, so what it is told
    /// matters. It must not read as success — the reminder does not exist yet.
    func testTheModelIsNotToldTheActionSucceeded() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createReminder, collector: collector)

        let output = try await tool.call(
            arguments: GeneratedContent(json: #"{"title":"Call the dentist"}"#)
        ).lowercased()

        for claim in ["done", "created", "scheduled", "succeeded", "added"] {
            XCTAssertFalse(output.contains(claim), "the output claims success: \(output)")
        }
        XCTAssertTrue(output.contains("nothing has happened yet"))
    }

    /// Draining is what stops one round's proposals being executed twice.
    func testDrainingClearsTheBuffer() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        _ = try await tool.call(arguments: GeneratedContent(json: #"{"title":"Only once"}"#))
        XCTAssertEqual(await collector.drain().count, 1)
        XCTAssertTrue(await collector.drain().isEmpty)
    }

    // MARK: Only registered tools exist

    /// The model is offered exactly the catalogue and nothing more. There is no
    /// string-to-function lookup anywhere in this provider, so there is no
    /// mechanism by which it could name something else and be obeyed.
    func testOnlyTheRequestedToolsAreExposed() throws {
        let collector = AppleFoundationToolCollector()
        let requested = [schema(for: .createTask), schema(for: .storeMemory)]

        let adapters = AppleFoundationToolAdapter.adapters(for: requested, collector: collector)

        XCTAssertEqual(adapters.count, 2)
        XCTAssertEqual(
            Set(adapters.map(\.name)),
            [ToolKind.createTask.rawValue, ToolKind.storeMemory.rawValue]
        )
    }

    func testTheWholeCatalogueTranslates() throws {
        let collector = AppleFoundationToolCollector()
        let everything = ToolKind.allCases.map { schema(for: $0) }

        let adapters = AppleFoundationToolAdapter.adapters(for: everything, collector: collector)

        // A tool whose schema failed to translate is silently dropped, which
        // would quietly remove a capability. Nothing in the catalogue should.
        XCTAssertEqual(
            adapters.count,
            everything.count,
            "some tools did not survive translation: " +
            "\(Set(everything.map(\.name)).subtracting(adapters.map(\.name)))"
        )
    }

    // MARK: Bad arguments

    /// A malformed argument set must fail rather than reach the engine as a
    /// half-formed proposal.
    func testUnreadableArgumentsFailWithoutProposingAnything() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        do {
            _ = try await tool.call(arguments: GeneratedContent(json: "{not json"))
            // `GeneratedContent(json:)` may itself reject this, which is the
            // same outcome by a shorter route.
        } catch {
            // Expected.
        }

        XCTAssertTrue(
            await collector.drain().isEmpty,
            "a failed conversion still proposed an action"
        )
    }

    /// Missing optional fields are the model's normal behaviour, not an error.
    /// The app's own decoder decides what is required — the adapter must not
    /// second-guess it, or there would be two validators disagreeing.
    func testMissingOptionalFieldsStillProduceAProposal() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        _ = try await tool.call(arguments: GeneratedContent(json: #"{"title":"Just a title"}"#))

        let calls = await collector.drain()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.arguments["importance"])
    }

    /// Whatever the model sends, the app's decoder is what decides. This is the
    /// join: the adapter's output has to be something `ToolRequestDecoder`
    /// accepts, or the two halves of the pipeline do not meet.
    func testAProposalSurvivesTheApplicationsOwnDecoder() async throws {
        let collector = AppleFoundationToolCollector()
        let tool = try adapter(for: .createTask, collector: collector)

        _ = try await tool.call(
            arguments: GeneratedContent(json: #"{"title":"Renew the passport","importance":"high"}"#)
        )
        let calls = await collector.drain()
        let call = try XCTUnwrap(calls.first)

        let decoded = ToolRequestDecoder().decode(
            [AIToolCallEnvelope(id: call.id, name: call.name, arguments: call.arguments)]
        )

        XCTAssertTrue(decoded.rejected.isEmpty, "\(decoded.rejected)")
        XCTAssertEqual(decoded.accepted.count, 1)
    }
}

#endif
