import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import Foundation
import MockPlatform
@testable import AssistantCore

// Shared stand-ins for the multi-round tests.
//
// Everything here is deterministic and in-memory. Nothing in these tests may
// need a network, a model, a calendar permission or a device — that is the CI
// rule, and it is also what makes a failure here mean something.

/// Replays a scripted sequence of responses, one per round.
///
/// The workhorse of the agent tests: a model whose every answer is decided in
/// advance, so a test can state exactly what "the model proposes X, sees the
/// result, then proposes Y" means and assert on what the application did with
/// it.
final class ScriptedRoundsProvider: AIProvider, @unchecked Sendable {
    struct Round {
        let text: String
        let toolCalls: [AIToolCall]

        init(text: String = "", toolCalls: [AIToolCall] = []) {
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    let metadata: AIProviderMetadata
    private let rounds: [Round]
    private let failAfterRounds: Int?
    private let lock = NSLock()
    private var calls = 0
    private var requests: [AIRequest] = []

    init(
        id: AIProviderIdentifier,
        supportsContinuation: Bool = true,
        rounds: [Round],
        failAfterRounds: Int? = nil
    ) {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: "Scripted \(id)",
            kind: .development,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 10,
            supportsToolResultContinuation: supportsContinuation
        )
        self.rounds = rounds
        self.failAfterRounds = failAfterRounds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var receivedRequests: [AIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// The tool messages the model was shown, in order. This is how a test
    /// asserts that the model really saw a result before its next decision.
    var toolMessagesSeen: [AIMessage] {
        receivedRequests.last?.messages.filter { $0.role == .tool } ?? []
    }

    func availability() async -> AIProviderAvailability { .available }

    func availableModels() async throws -> [AIModel] { [] }

    func respond(to request: AIRequest) async throws -> AIResponse {
        lock.lock()
        let index = calls
        calls += 1
        requests.append(request)
        let shouldFail = failAfterRounds.map { index >= $0 } ?? false
        lock.unlock()

        if shouldFail {
            throw AIProviderError.transport("scripted failure")
        }

        let round = rounds[min(index, rounds.count - 1)]
        return AIResponse(
            text: round.text,
            toolCalls: round.toolCalls,
            stopReason: round.toolCalls.isEmpty ? .endTurn : .toolCalls,
            providerID: metadata.id
        )
    }
}

/// A calendar that fails a set number of times before it works.
///
/// Models the case the retry policy exists for — a save that fails once and
/// succeeds a moment later — and counts attempts, which is how a test proves the
/// retry happened once rather than never or forever.
final class FlakyCalendarService: CalendarService, @unchecked Sendable {
    let platformName = "FlakyCalendar"
    let fidelity: PlatformFidelity = .simulated

    private let lock = NSLock()
    private var remainingFailures: Int
    private var stored: [CalendarItem.ID: CalendarItem] = [:]
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.remainingFailures = failuresBeforeSuccess
    }

    var createAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func createEvent(_ item: CalendarItem) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        lock.lock()
        attempts += 1
        let failing = remainingFailures > 0
        if failing { remainingFailures -= 1 } else { stored[item.id] = item }
        lock.unlock()

        if failing {
            // `.underlying` is what the executor maps to `temporaryFailure`,
            // the only category besides a network error that may be retried.
            throw PlatformError.underlying("the calendar was busy")
        }
        return (
            item,
            PlatformReceipt(
                description: "Event created: \(item.title)",
                fidelity: fidelity,
                platformName: platformName
            )
        )
    }

    func updateEvent(_ item: CalendarItem) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        lock.lock()
        stored[item.id] = item
        lock.unlock()
        return (
            item,
            PlatformReceipt(description: "Event updated", fidelity: fidelity, platformName: platformName)
        )
    }

    func deleteEvent(id: CalendarItem.ID) async throws -> PlatformReceipt {
        lock.lock()
        stored.removeValue(forKey: id)
        lock.unlock()
        return PlatformReceipt(
            description: "Event deleted",
            fidelity: fidelity,
            platformName: platformName
        )
    }

    func event(id: CalendarItem.ID) async throws -> CalendarItem? {
        lock.lock()
        defer { lock.unlock() }
        return stored[id]
    }

    func events(in window: TimeWindow) async throws -> [CalendarItem] {
        lock.lock()
        defer { lock.unlock() }
        return stored.values
            .filter { $0.start >= window.start && $0.start <= window.end }
            .sorted { $0.start < $1.start }
    }
}

/// Records every action it is handed, then delegates.
///
/// Used to prove what ran, in what order, and that nothing ran twice.
struct RecordingToolExecutor: ToolExecutor {
    let inner: any ToolExecutor
    let log: ExecutionLog

    func execute(_ plan: AssistantActionPlan, context: AssistantContext) async -> [ToolResult] {
        for action in plan.actions {
            await log.append(action.kind)
        }
        return await inner.execute(plan, context: context)
    }
}

actor ExecutionLog {
    private(set) var kinds: [ToolKind] = []

    func append(_ kind: ToolKind) { kinds.append(kind) }

    func all() -> [ToolKind] { kinds }

    func count(of kind: ToolKind) -> Int { kinds.filter { $0 == kind }.count }
}

/// Somewhere for a test to put the turn it is running, so a fixture can cancel
/// it from inside.
actor TurnHandle {
    private var turn: Task<AssistantTurnResult, any Error>?

    func set(_ turn: Task<AssistantTurnResult, any Error>) { self.turn = turn }

    func cancel() { turn?.cancel() }
}

/// A scripted provider that cancels the turn part way through.
///
/// The only honest way to test cancellation: the user taps stop while the
/// assistant is working, which means the cancellation lands *between* two
/// actions rather than before the first one. Racing `Task.cancel()` from the
/// outside would test the scheduler, not the loop.
final class CancellingProvider: AIProvider, @unchecked Sendable {
    let metadata: AIProviderMetadata
    private let handle: TurnHandle
    private let cancelBeforeRound: Int
    private let rounds: [ScriptedRoundsProvider.Round]
    private let lock = NSLock()
    private var calls = 0

    init(
        id: AIProviderIdentifier,
        handle: TurnHandle,
        cancelBeforeRound: Int,
        rounds: [ScriptedRoundsProvider.Round]
    ) {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: "Cancelling \(id)",
            kind: .development,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 10,
            supportsToolResultContinuation: true
        )
        self.handle = handle
        self.cancelBeforeRound = cancelBeforeRound
        self.rounds = rounds
    }

    func availability() async -> AIProviderAvailability { .available }

    func availableModels() async throws -> [AIModel] { [] }

    func respond(to request: AIRequest) async throws -> AIResponse {
        lock.lock()
        let index = calls
        calls += 1
        lock.unlock()

        if index + 1 == cancelBeforeRound {
            await handle.cancel()
        }

        let round = rounds[min(index, rounds.count - 1)]
        return AIResponse(
            text: round.text,
            toolCalls: round.toolCalls,
            stopReason: round.toolCalls.isEmpty ? .endTurn : .toolCalls,
            providerID: metadata.id
        )
    }
}
