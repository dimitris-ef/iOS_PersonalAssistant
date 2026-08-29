import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// Turning a file that stops abruptly into "it was inside `context_create`".
///
/// This is the payload of the whole diagnostic pass. Everything else — the
/// writer, the rotation, the UI — exists so that these functions have something
/// to read.
final class LocalInferenceRecoveryTests: XCTestCase {

    private let session = LocalInferenceSessionID(rawValue: "session-under-test")
    private var sequence = 0

    override func setUp() {
        super.setUp()
        sequence = 0
    }

    private func event(
        _ type: LocalInferenceEventType,
        stage: LocalInferenceStage? = nil,
        operation: LocalInferenceOperationID? = nil,
        name: LocalInferenceEventName = .stage,
        level: LocalInferenceDiagnosticLevel = .info,
        metadata: LocalInferenceMetadata = .empty
    ) -> LocalInferenceDiagnosticEvent {
        sequence += 1
        return LocalInferenceDiagnosticEvent(
            appSessionID: session,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_781_078_400 + Double(sequence)),
            elapsed: Double(sequence),
            level: level,
            category: .runtime,
            type: type,
            name: name,
            stage: stage,
            operationID: operation,
            metadata: metadata
        )
    }

    private func summarize(
        _ events: [LocalInferenceDiagnosticEvent],
        unreadable: Int = 0
    ) -> LocalInferenceRecoverySummary {
        LocalInferenceSessionRecovery.summarize(
            LocalInferenceDecodedSession(events: events, unreadableLineCount: unreadable),
            sessionID: session,
            endedAt: Date(timeIntervalSince1970: 1_781_078_500)
        )
    }

    // MARK: Pairing

    /// Section 100.
    func testAMatchedEnterAndExitLeavesNothingUnresolved() {
        let operation = LocalInferenceOperationID(rawValue: "A")
        let summary = summarize([
            event(.enter, stage: .modelLoad, operation: operation),
            event(.exit, stage: .modelLoad, operation: operation),
        ])
        XCTAssertTrue(summary.unresolvedStages.isEmpty)
        XCTAssertNil(summary.deepestUnresolvedStage)
        XCTAssertEqual(summary.lastCompletedStage, .modelLoad)
    }

    /// Section 101. The central case.
    func testAnEnterWithNoExitIsRecoveredAsTheStageItStoppedIn() {
        let summary = summarize([
            event(.enter, stage: .contextCreate, operation: LocalInferenceOperationID(rawValue: "A"))
        ])
        XCTAssertEqual(summary.deepestUnresolvedStage?.stage, .contextCreate)
        XCTAssertEqual(summary.unresolvedStages.count, 1)
        XCTAssertFalse(summary.endedCleanly)
        XCTAssertTrue(summary.isReportable)
        XCTAssertEqual(
            summary.stageDescription,
            "Termination occurred after: ENTER context_create. No matching EXIT was recorded."
        )
    }

    /// Section 102. Nesting: the inner stage finished, the outer did not.
    func testNestedStagesResolveToTheEnclosingStage() {
        let outer = LocalInferenceOperationID(rawValue: "A")
        let inner = LocalInferenceOperationID(rawValue: "B")
        let summary = summarize([
            event(.enter, stage: .generation, operation: outer),
            event(.enter, stage: .generationDecode, operation: inner),
            event(.exit, stage: .generationDecode, operation: inner),
        ])
        XCTAssertEqual(summary.unresolvedStages.map(\.stage), [.generation])
        XCTAssertEqual(summary.deepestUnresolvedStage?.stage, .generation)
    }

    /// And the reverse: with both open, the innermost is the answer, because
    /// "it was inside generation" is true and useless next to "it was inside
    /// the decode".
    func testTheDeepestOpenStageIsTheOneReported() {
        let summary = summarize([
            event(.enter, stage: .inference, operation: LocalInferenceOperationID(rawValue: "A")),
            event(.enter, stage: .generation, operation: LocalInferenceOperationID(rawValue: "B")),
            event(.enter, stage: .promptDecode, operation: LocalInferenceOperationID(rawValue: "C")),
        ])
        XCTAssertEqual(summary.deepestUnresolvedStage?.stage, .promptDecode)
        XCTAssertEqual(summary.unresolvedStages.count, 3)
    }

    /// Section 103, and the reason operation identifiers exist at all: pairing
    /// by stage name would match the second ENTER against the first EXIT and
    /// report a stage that completed twice as the crash site.
    func testARepeatedStageResolvesByOperationNotByName() {
        let first = LocalInferenceOperationID(rawValue: "A")
        let second = LocalInferenceOperationID(rawValue: "B")
        let summary = summarize([
            event(.enter, stage: .promptDecode, operation: first),
            event(.exit, stage: .promptDecode, operation: first),
            event(.enter, stage: .promptDecode, operation: second),
        ])
        XCTAssertEqual(summary.unresolvedStages.count, 1)
        XCTAssertEqual(summary.deepestUnresolvedStage?.operationID, second)
    }

    /// A stage that threw still came back. It is not the crash site, and
    /// reporting it as one would send the investigation to the wrong file.
    func testAFailedStageIsResolvedRatherThanReportedAsTheCrashSite() {
        let operation = LocalInferenceOperationID(rawValue: "A")
        let summary = summarize([
            event(.enter, stage: .modelLoad, operation: operation),
            event(.exit, stage: .modelLoad, operation: operation, level: .error),
        ])
        XCTAssertTrue(summary.unresolvedStages.isEmpty)
    }

    /// The metadata on the ENTER is what makes the report actionable: the
    /// context size it was about to allocate is usually the whole answer.
    func testTheUnresolvedEnterKeepsItsMetadata() {
        let summary = summarize([
            event(
                .enter, stage: .contextCreate,
                operation: LocalInferenceOperationID(rawValue: "A"),
                metadata: LocalInferenceMetadata().setting(.requestedContextSize, 4096)
            )
        ])
        XCTAssertEqual(
            summary.deepestUnresolvedStage?.metadata[.requestedContextSize], .int(4096)
        )
    }

    // MARK: Clean and unclean

    /// Section 105.
    func testACleanSessionIsNotReportedAsUnexpected() {
        let operation = LocalInferenceOperationID(rawValue: "A")
        let summary = summarize([
            event(.enter, stage: .modelLoad, operation: operation),
            event(.exit, stage: .modelLoad, operation: operation),
            event(
                .state, name: .sessionEnd,
                metadata: LocalInferenceMetadata().setting(.clean, true)
            ),
        ])
        XCTAssertTrue(summary.endedCleanly)
        XCTAssertFalse(summary.isReportable)
    }

    /// Section 97. Ending badly is not the same as ending badly *in Local AI*,
    /// and blaming the local model for a crash somewhere else would cost
    /// somebody a week.
    func testASessionThatNeverUsedLocalAIIsNotReportable() {
        let summary = summarize([
            event(.info, name: .appLaunch),
            event(.info, name: .providerSelected),
        ])
        XCTAssertFalse(summary.endedCleanly)
        XCTAssertFalse(summary.enteredLocalInference)
        XCTAssertFalse(summary.isReportable, "a non-local crash would have blamed Local AI")
    }

    func testASessionThatReachedInferenceIsReportable() {
        let summary = summarize([
            event(.info, name: .appLaunch),
            event(.state, name: .inferenceSessionStart),
        ])
        XCTAssertTrue(summary.enteredLocalInference)
        XCTAssertTrue(summary.isReportable)
    }

    /// Sections 50 and 51, as an assertion rather than a comment: the summary
    /// must not contain a cause.
    func testTheSummaryNamesAPlaceAndNeverACause() {
        let summary = summarize([
            event(.enter, stage: .contextCreate, operation: LocalInferenceOperationID(rawValue: "A"))
        ])
        let text = [
            summary.headline,
            summary.stageDescription ?? "",
            summary.lastCompletedDescription ?? "",
            LocalInferenceRecoverySummary.terminationReasonCaveat,
        ].joined(separator: " ").lowercased()

        for forbidden in ["out of memory", "out-of-memory", "jetsam", "oom", "crashed"] {
            XCTAssertFalse(
                text.contains(forbidden),
                "the recovery summary claimed '\(forbidden)', which iOS never told it"
            )
        }
        XCTAssertTrue(text.contains("not available to the app"))
    }

    // MARK: Reading a file

    /// Section 104: a new logger recognises what the previous one left.
    func testANewLoggerRecoversThePreviousUncleanSession() {
        let store = LocalInferenceDiagnosticStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        // A session that opens a stage and is then "killed" — no exit, no
        // clean marker, and no chance to tidy up.
        let first = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        first.startSession(metadata: .empty)
        _ = first.criticalEnter(
            .promptDecode,
            metadata: LocalInferenceMetadata().setting(.promptTokenCount, 812)
        )

        // Section 111: a fresh logger, as the next launch would build.
        let second = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        guard let recovery = second.recovery else {
            return XCTFail("the previous session was not recovered at all")
        }

        XCTAssertEqual(recovery.sessionID, first.appSessionID)
        XCTAssertFalse(recovery.endedCleanly)
        XCTAssertTrue(recovery.isReportable)
        XCTAssertEqual(recovery.deepestUnresolvedStage?.stage, .promptDecode)
        XCTAssertEqual(
            recovery.deepestUnresolvedStage?.metadata[.promptTokenCount], .int(812)
        )
    }

    func testACleanlyClosedSessionIsRecoveredAsClean() {
        let store = LocalInferenceDiagnosticStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let first = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        first.startSession(metadata: .empty)
        let operation = first.criticalEnter(.modelLoad, metadata: .empty)
        first.criticalExit(.modelLoad, operation: operation, metadata: .empty)
        first.endSession(clean: true)

        let second = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        XCTAssertEqual(second.recovery?.endedCleanly, true)
        XCTAssertEqual(second.recovery?.isReportable, false)
    }

    /// Section 82 and 112. A process killed mid-`write` leaves a partial final
    /// line, and discarding the whole file over it would throw away the trail
    /// leading to the crash being investigated.
    func testATruncatedFinalLineDoesNotDiscardTheEarlierEvents() throws {
        let store = LocalInferenceDiagnosticStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.prepareDirectory()

        let id = LocalInferenceSessionID()
        let url = store.url(forSession: id)
        let good = [
            #"{"seq":1,"event":"INFO","name":"APP_LAUNCH","app":"\#(id.rawValue)"}"#,
            #"{"seq":2,"event":"ENTER","name":"STAGE","stage":"context_create","op":"A","app":"\#(id.rawValue)"}"#,
        ].joined(separator: "\n")
        // The half-written record, exactly as an interrupted `write` leaves it.
        let truncated = #"{"seq":3,"event":"EXIT","name":"STAGE","stage":"cont"#
        try Data((good + "\n" + truncated).utf8).write(to: url)

        let decoded = try XCTUnwrap(store.read(session: id))
        XCTAssertEqual(decoded.events.count, 2, "the readable events were thrown away")
        XCTAssertEqual(decoded.unreadableLineCount, 1)

        // And the recovery still works off what survived.
        let summary = LocalInferenceSessionRecovery.summarize(
            decoded, sessionID: id, endedAt: Date()
        )
        XCTAssertEqual(summary.deepestUnresolvedStage?.stage, .contextCreate)
    }

    /// A garbled line in the *middle* is just as possible and just as
    /// survivable — a torn write is not only a tail phenomenon.
    func testAGarbledLineInTheMiddleIsSkipped() throws {
        let store = LocalInferenceDiagnosticStore.temporary()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.prepareDirectory()

        let id = LocalInferenceSessionID()
        let lines = [
            #"{"seq":1,"event":"INFO","name":"APP_LAUNCH","app":"\#(id.rawValue)"}"#,
            "!!! not json at all !!!",
            #"{"seq":3,"event":"INFO","name":"FIRST_TOKEN","app":"\#(id.rawValue)"}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8)
            .write(to: store.url(forSession: id))

        let decoded = try XCTUnwrap(store.read(session: id))
        XCTAssertEqual(decoded.events.map(\.sequence), [1, 3])
        XCTAssertEqual(decoded.unreadableLineCount, 1)
    }
}
