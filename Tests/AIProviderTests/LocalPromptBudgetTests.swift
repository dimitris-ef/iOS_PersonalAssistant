import AssistantAI
import AssistantDomain
import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// Keeping a prompt inside the context the model was actually opened with.
///
/// Sections 52 and 53. A phone context is small — 2048 tokens on a 4 GB device
/// — and a conversation plus its retrieved memories plus the tool schemas
/// passes that without anybody watching. llama.cpp does not politely truncate
/// an oversized prompt; it is asked to decode more tokens than the context
/// holds, and what happens next is not a Swift error anything can catch.
final class LocalPromptBudgetTests: XCTestCase {

    private func words(_ tokens: Int) -> String {
        // Four characters per token is the estimator's own ratio, so a string
        // built this way has a predictable cost.
        String(repeating: "a", count: tokens * LocalPromptBudget.charactersPerToken)
    }

    private let small = LocalInferenceConfiguration(
        contextLength: 1024,
        batchSize: 128,
        microBatchSize: 64,
        threadCount: 2,
        maximumGenerationTokens: 256,
        generationReserveTokens: 256
    )

    // MARK: Leaving it alone

    func testAPromptThatAlreadyFitsIsUntouched() {
        let prompt = LocalPrompt(turns: [
            .system(words(20)),
            .user(words(20)),
        ])
        let fit = LocalPromptBudget.fit(prompt, configuration: small)

        XCTAssertFalse(fit.wasTrimmed)
        XCTAssertEqual(fit.droppedTurns, 0)
        XCTAssertEqual(fit.prompt, prompt)
    }

    // MARK: Trimming

    /// The central case: forty turns of history against a 768-token budget.
    func testALongConversationIsTrimmedToFitTheRealContext() {
        var turns: [LocalChatTurn] = [.system(words(50))]
        for index in 0..<40 {
            turns.append(.user("message \(index) " + words(40)))
            turns.append(.assistant("reply \(index) " + words(40)))
        }
        turns.append(.user("what did I just ask?"))

        let fit = LocalPromptBudget.fit(
            LocalPrompt(turns: turns), configuration: small
        )

        XCTAssertTrue(fit.wasTrimmed)
        XCTAssertGreaterThan(fit.droppedTurns, 0)
        XCTAssertLessThanOrEqual(
            LocalPromptBudget.estimatedTokens(in: fit.prompt),
            small.maximumPromptTokens,
            "the trimmed prompt still exceeds the context it was trimmed for"
        )
    }

    /// The system prompt carries the app's instructions and the tool protocol.
    /// Dropping it produces a model that has forgotten what it is and cannot
    /// form an action — a far worse outcome than a short memory.
    func testTheSystemPromptSurvivesTrimming() {
        var turns: [LocalChatTurn] = [.system("SYSTEM MARKER " + words(30))]
        for index in 0..<60 {
            turns.append(.user("m\(index) " + words(40)))
        }

        let fit = LocalPromptBudget.fit(
            LocalPrompt(turns: turns), configuration: small
        )

        XCTAssertEqual(fit.prompt.turns.first?.role, "system")
        XCTAssertTrue(
            fit.prompt.turns.first?.content.contains("SYSTEM MARKER") ?? false,
            "the system prompt was dropped or replaced"
        )
    }

    /// Dropping the message somebody just typed to make room for the
    /// conversation about it is absurd, so it survives even when trimming is
    /// severe.
    func testTheNewestMessageAlwaysSurvives() {
        var turns: [LocalChatTurn] = [.system(words(40))]
        for index in 0..<60 {
            turns.append(.user("old \(index) " + words(40)))
        }
        turns.append(.user("NEWEST QUESTION"))

        let fit = LocalPromptBudget.fit(
            LocalPrompt(turns: turns), configuration: small
        )

        XCTAssertEqual(fit.prompt.turns.last?.content, "NEWEST QUESTION")
    }

    /// The oldest go first: recency is what a follow-up question depends on.
    func testTheMostRecentHistoryIsWhatIsKept() {
        var turns: [LocalChatTurn] = [.system(words(20))]
        for index in 0..<40 {
            turns.append(.user("turn-\(index) " + words(40)))
        }
        turns.append(.user("latest"))

        let fit = LocalPromptBudget.fit(
            LocalPrompt(turns: turns), configuration: small
        )
        let kept = fit.prompt.turns.map(\.content).joined(separator: "\n")

        XCTAssertFalse(kept.contains("turn-0 "), "the oldest turn was kept over a newer one")
        XCTAssertTrue(kept.contains("turn-39 "), "the newest history was dropped")
    }

    /// A single message longer than the whole context. It is cut down rather
    /// than removed — a truncated question is answerable, a missing one is not
    /// — and the *end* is what survives, because that is where the question is.
    func testAnEnormousSingleMessageIsTruncatedRatherThanDropped() {
        let prompt = LocalPrompt(turns: [
            .system(words(30)),
            .user(words(4000) + " ...and what should I do about it?"),
        ])

        let fit = LocalPromptBudget.fit(prompt, configuration: small)

        XCTAssertTrue(fit.wasTrimmed)
        XCTAssertEqual(fit.prompt.turns.count, 2)
        XCTAssertTrue(
            fit.prompt.turns.last?.content.hasSuffix("what should I do about it?") ?? false,
            "the tail of the message — the part with the question in it — was cut"
        )
        XCTAssertLessThanOrEqual(
            LocalPromptBudget.estimatedTokens(in: fit.prompt),
            small.maximumPromptTokens
        )
    }

    /// The estimate errs toward trimming one turn too many. Being slightly too
    /// cautious costs a line of old conversation; being slightly too generous
    /// costs the app.
    func testTheEstimateChargesForTemplateOverheadPerTurn() {
        let one = LocalPrompt(turns: [.user(words(10))])
        let two = LocalPrompt(turns: [.user(words(5)), .user(words(5))])

        XCTAssertGreaterThan(
            LocalPromptBudget.estimatedTokens(in: two),
            LocalPromptBudget.estimatedTokens(in: one),
            "the same text split across two turns costs more, because markers do"
        )
    }

    func testAnEmptyPromptCostsNothing() {
        XCTAssertEqual(LocalPromptBudget.estimatedTokens(in: LocalPrompt(turns: [])), 0)
        XCTAssertEqual(LocalPromptBudget.estimatedTokens(in: ""), 0)
    }

    /// The template survives the trim. It decides how the turns are rendered,
    /// and losing it means a model trained on markers gets labelled plain text.
    func testTheChatTemplateIsPreserved() {
        var turns: [LocalChatTurn] = [.system(words(30))]
        for index in 0..<50 { turns.append(.user("m\(index) " + words(40))) }

        let fit = LocalPromptBudget.fit(
            LocalPrompt(turns: turns, fallback: .chatML), configuration: small
        )
        XCTAssertEqual(fit.prompt.fallback, .chatML)
    }

    // MARK: The reply has to fit too

    /// Bounding the prompt alone still allows a 1024-token context to be given
    /// a 900-token prompt and asked for 640 tokens back.
    func testTheReplyIsBoundedByWhatIsLeftOfTheContext() {
        let limit = LocalPromptBudget.generationLimit(
            promptTokens: 900, requested: 640, configuration: small
        )
        XCTAssertLessThanOrEqual(limit, small.contextLength - 900)
    }

    func testARequestSmallerThanTheRoomIsHonoured() {
        let limit = LocalPromptBudget.generationLimit(
            promptTokens: 100, requested: 200, configuration: small
        )
        XCTAssertEqual(limit, 200)
    }

    /// Never zero: a reply of no tokens is not an outcome anything upstream can
    /// render, and it would look like the model refusing to answer.
    func testAFullContextStillAllowsSomeReply() {
        let limit = LocalPromptBudget.generationLimit(
            promptTokens: small.contextLength + 500, requested: 640, configuration: small
        )
        XCTAssertGreaterThan(limit, 0)
    }

    // MARK: Against the real device tiers

    /// Whatever the device, a prompt trimmed for it fits it. Written as a loop
    /// because the tier that breaks will be the one nobody wrote a case for.
    func testEveryDeviceTierProducesAPromptThatFitsIt() {
        var turns: [LocalChatTurn] = [.system(words(200))]
        for index in 0..<200 { turns.append(.user("m\(index) " + words(60))) }
        let prompt = LocalPrompt(turns: turns)

        for device in [
            FixedDeviceResources.smallPhone,
            .midPhone,
            .largePhone,
        ] {
            let configuration = LocalInferenceConfiguration.forDevice(device)
            let fit = LocalPromptBudget.fit(prompt, configuration: configuration)
            XCTAssertLessThanOrEqual(
                LocalPromptBudget.estimatedTokens(in: fit.prompt),
                configuration.maximumPromptTokens
            )
            XCTAssertLessThan(
                LocalPromptBudget.estimatedTokens(in: fit.prompt),
                configuration.contextLength,
                "a prompt at or past the context leaves the model no room to answer"
            )
        }
    }
}

/// What pressing Send does when Local AI is the chosen assistant.
///
/// Sections 47 and 48. Three situations that "just try it" collapses into one
/// spinner: ready, needs loading, and cannot answer at all.
final class LocalTurnPreflightTests: XCTestCase {

    func testAResidentModelStartsTheTurnImmediately() {
        XCTAssertEqual(
            LocalTurnPreflight.decide(availability: .ready, modelName: "Qwen3 1.7B"),
            .proceed
        )
    }

    /// The state this whole pass creates on purpose: downloaded, selected, and
    /// deliberately not in memory until somebody asks something.
    func testADownloadedModelIsLoadedOnDemandRatherThanRefused() {
        let decision = LocalTurnPreflight.decide(
            availability: .modelDownloaded, modelName: "Qwen3 1.7B"
        )
        guard case .loadFirst(let notice) = decision else {
            return XCTFail("a downloaded model should load on Send, got \(decision)")
        }
        XCTAssertTrue(
            notice.contains("Qwen3 1.7B"),
            "an unnamed 'Loading…' during a five-second pause explains nothing"
        )
        XCTAssertTrue(decision.startsATurn)
    }

    func testTheNoticeStillReadsWithoutAModelName() {
        guard case .loadFirst(let notice) = LocalTurnPreflight.decide(
            availability: .modelDownloaded, modelName: nil
        ) else {
            return XCTFail("expected loadFirst")
        }
        XCTAssertFalse(notice.isEmpty)
    }

    /// A load already in flight is waited for, not started again — two
    /// multi-gigabyte allocations in flight at once is the thing the whole
    /// memory budget exists to prevent.
    func testALoadInFlightIsWaitedForRatherThanStartedAgain() {
        XCTAssertEqual(
            LocalTurnPreflight.decide(availability: .modelLoading, modelName: "A"),
            .loadFirst(notice: "Loading A…")
        )
    }

    // MARK: Refusals

    func testNothingDownloadedRefusesAndPointsSomewhere() {
        guard case .refuse(let reason) = LocalTurnPreflight.decide(
            availability: .noModelInstalled, modelName: nil
        ) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(
            reason.contains("Manage Models"),
            "a refusal with no route out is a dead end: \(reason)"
        )
    }

    /// Section 128, as a test rather than a comment. Someone who chose an
    /// on-device model chose it for a reason, and quietly sending their message
    /// to a remote service because the local one ran out of memory is the one
    /// thing this must never do.
    func testRunningOutOfMemoryRefusesRatherThanFallingBackToTheCloud() {
        let decision = LocalTurnPreflight.decide(
            availability: .insufficientMemory(reason: "Try a smaller model."),
            modelName: "Big"
        )
        XCTAssertEqual(decision, .refuse(reason: "Try a smaller model."))
        XCTAssertFalse(decision.startsATurn)
    }

    func testEveryUnusableStateRefusesWithSomethingToRead() {
        let unusable: [LocalModelAvailability] = [
            .noModelInstalled,
            .modelIncompatible(reason: "Unsupported architecture."),
            .insufficientMemory(reason: "Not enough memory."),
            .corruptedModel(reason: "The model file is missing."),
            .runtimeUnavailable(reason: "This build has no inference runtime."),
        ]
        for availability in unusable {
            guard case .refuse(let reason) = LocalTurnPreflight.decide(
                availability: availability, modelName: "A"
            ) else {
                return XCTFail("\(availability) started a turn it cannot finish")
            }
            XCTAssertFalse(reason.isEmpty, "\(availability) refused without saying why")
        }
    }

    // MARK: Load failures

    /// "The model could not be loaded" is actionable — pick a smaller one.
    /// "The model could not answer" is not, and the two must not read alike.
    func testALoadFailureExplainsItselfInTheUsersTerms() {
        let message = LocalTurnPreflight.loadFailureMessage(
            .insufficientMemory(reason: "Needs about 3 GB; try a smaller model.")
        )
        XCTAssertEqual(message, "Needs about 3 GB; try a smaller model.")

        let missing = LocalTurnPreflight.loadFailureMessage(
            .modelFileMissing(URL(fileURLWithPath: "/tmp/model.gguf"))
        )
        XCTAssertTrue(missing.contains("Manage Models"))
        XCTAssertFalse(
            missing.contains("/tmp/"),
            "a sandbox path is something nobody can act on (section 90)"
        )
    }
}
