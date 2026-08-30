import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal
@testable import AIProviderLocalLlama

/// The first native `llama_decode`, and everything written around it.
///
/// ## Why these are the tests and not others
///
/// The failure this pass exists for cannot be reproduced in CI: there is no
/// iOS-simulator slice of the llama.cpp framework, and section 85 forbids
/// running a real multi-gigabyte decode here even where there were. So what is
/// testable is the part that decides *whether the call happens at all* and the
/// part that decides *what a reader is told afterwards* — the batch arithmetic,
/// the return-code taxonomy, the native-log filter and the export.
///
/// That is deliberate rather than a compromise. Every one of those is a place
/// where a wrong answer would send the next reader of a crash log to the wrong
/// conclusion, and a wrong conclusion followed for a week is the actual cost
/// being defended against.
final class LocalDecodeBoundaryTests: XCTestCase {

    // MARK: The batch validator

    /// The canonical prefill shape, which must pass unchanged.
    private func validBatch(
        tokens: Int = 12,
        capacity: Int? = nil,
        batchLimit: Int = 512,
        contextSize: Int = 2048
    ) -> LocalDecodeBatchDescriptor {
        LocalDecodeBatchDescriptor(
            nTokens: tokens,
            tokenBufferCount: tokens,
            allocatedCapacity: capacity ?? tokens,
            contextBatchLimit: batchLimit,
            contextSize: contextSize,
            positionCount: tokens,
            firstPosition: 0,
            lastPosition: tokens - 1,
            sequenceCount: tokens,
            logitsCount: tokens,
            logitsTrueCount: 1
        )
    }

    /// Section 78. The shape the bridge actually builds is accepted — otherwise
    /// every other assertion here would be testing a validator nothing can pass.
    func testTheCanonicalPrefillBatchIsAccepted() {
        XCTAssertNil(LocalDecodeBatchValidator.validate(validBatch()))
    }

    /// Section 75. An empty batch is the one case llama.cpp is documented to
    /// reject with -1, and the one this app can refuse for free.
    func testAnEmptyBatchIsRejected() {
        var batch = validBatch()
        batch.nTokens = 0
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "invalidTokenCount"
        )
    }

    func testANegativeTokenCountIsRejected() {
        var batch = validBatch()
        batch.nTokens = -3
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "invalidTokenCount"
        )
    }

    /// Section 76. A batch larger than the allocation is a read past the end of
    /// a heap buffer — precisely the class of fault that ends a process without
    /// returning a code.
    func testABatchLargerThanItsAllocationIsRejected() {
        let batch = validBatch(tokens: 64, capacity: 32)
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "batchExceedsCapacity"
        )
    }

    func testABatchLargerThanTheContextBatchLimitIsRejected() {
        let batch = validBatch(tokens: 600, batchLimit: 512)
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "batchExceedsContextLimit"
        )
    }

    func testABatchLargerThanTheContextIsRejected() {
        let batch = validBatch(tokens: 4096, batchLimit: 8192, contextSize: 2048)
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "batchExceedsContextSize"
        )
    }

    /// Section 77. `n_tokens` is read back off the struct and the buffer count
    /// is what Swift believes it wrote; when they disagree, one of the two is
    /// lying and llama.cpp will trust the struct.
    func testAnNTokensThatDisagreesWithTheBufferIsRejected() {
        var batch = validBatch(tokens: 10)
        batch.nTokens = 11
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "tokenCountMismatch"
        )
    }

    func testAShortPositionArrayIsRejected() {
        var batch = validBatch(tokens: 10)
        batch.positionCount = 9
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "positionCountMismatch"
        )
    }

    func testANegativePositionIsRejected() {
        var batch = validBatch()
        batch.firstPosition = -1
        XCTAssertEqual(LocalDecodeBatchValidator.validate(batch)?.symbol, "negativePosition")
    }

    func testAShortSequenceArrayIsRejected() {
        var batch = validBatch(tokens: 10)
        batch.sequenceCount = 4
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "invalidSequenceMetadata"
        )
    }

    func testAShortLogitsArrayIsRejected() {
        var batch = validBatch(tokens: 10)
        batch.logitsCount = 3
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "logitsCountMismatch"
        )
    }

    /// A prefill that flags no logits decodes cleanly and then has nothing to
    /// sample, which surfaces much later as an empty or nonsense reply.
    func testABatchThatRequestsNoLogitsIsRejected() {
        var batch = validBatch()
        batch.logitsTrueCount = 0
        XCTAssertEqual(LocalDecodeBatchValidator.validate(batch)?.symbol, "noLogitsRequested")
    }

    func testABatchInBothTokenAndEmbeddingModeIsRejected() {
        var batch = validBatch()
        batch.usesEmbeddings = true
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "bothTokensAndEmbeddings"
        )
    }

    func testABatchInNeitherModeIsRejected() {
        var batch = validBatch()
        batch.usesTokens = false
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(batch)?.symbol, "neitherTokensNorEmbeddings"
        )
    }

    /// The null-pointer mode llama.cpp also accepts: no positions, no sequence
    /// metadata, no logits flags, all inferred. Valid, and recorded as
    /// "automatic" so a log says which of the two shapes was used.
    func testTheInferredPointerModeIsAcceptedAndLabelled() {
        let batch = LocalDecodeBatchDescriptor(
            nTokens: 8,
            tokenBufferCount: 8,
            allocatedCapacity: 8,
            contextBatchLimit: 512,
            contextSize: 2048
        )
        XCTAssertNil(LocalDecodeBatchValidator.validate(batch))
        let metadata = batch.metadata()
        XCTAssertEqual(metadata[.positionsMode], .text("automatic"))
        XCTAssertEqual(metadata[.sequenceMode], .text("default"))
        XCTAssertEqual(metadata[.logitsPointerPresent], .bool(false))
    }

    /// Section 60: the explicit shape says so, so the two are distinguishable
    /// in a log from a build nobody has the source of any more.
    func testTheExplicitPointerModeIsLabelledDifferently() {
        let metadata = validBatch().metadata()
        XCTAssertEqual(metadata[.positionsMode], .text("explicit"))
        XCTAssertEqual(metadata[.sequenceMode], .text("explicit"))
        XCTAssertEqual(metadata[.logitsPointerPresent], .bool(true))
        XCTAssertEqual(metadata[.logitsTrueCount], .int(1))
    }

    // MARK: The return code

    /// Section 54, and the reason this enum exists at all. The header documents
    /// five outcomes and the previous code reported one sentence for all of
    /// them.
    func testEveryDocumentedReturnCodeMapsToItsOwnOutcome() {
        XCTAssertEqual(LocalDecodeResult(returnCode: 0), .success)
        XCTAssertEqual(LocalDecodeResult(returnCode: 1), .noKVSlot)
        XCTAssertEqual(LocalDecodeResult(returnCode: 2), .aborted)
        XCTAssertEqual(LocalDecodeResult(returnCode: -1), .invalidBatch)
        XCTAssertEqual(LocalDecodeResult(returnCode: -7), .fatal(-7))
        XCTAssertEqual(LocalDecodeResult(returnCode: 42), .unknown(42))
    }

    func testOnlyZeroCountsAsSuccess() {
        XCTAssertTrue(LocalDecodeResult(returnCode: 0).isSuccess)
        for code in [1, 2, -1, -9, 99] {
            XCTAssertFalse(LocalDecodeResult(returnCode: code).isSuccess, "code \(code)")
        }
    }

    /// The point of separating them: a context too small and a malformed batch
    /// are different problems with different owners, and the user is told so.
    func testNoKVSlotAndInvalidBatchDoNotReadTheSame() {
        let noSlot = LocalDecodeResult.noKVSlot.explanation
        let invalid = LocalDecodeResult.invalidBatch.explanation
        XCTAssertNotEqual(noSlot, invalid)
        XCTAssertTrue(noSlot.contains("context"))
        // Section 53: a bridge bug is owned by the app, and says so rather than
        // implying the user typed something wrong.
        XCTAssertTrue(invalid.contains("MetisAI"))
    }

    // MARK: Native log severity

    /// The ggml numbering from the pinned header: NONE=0, DEBUG=1, INFO=2,
    /// WARN=3, ERROR=4, CONT=5.
    func testGgmlLevelsMapToSeverities() {
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 4), .error)
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 3), .warning)
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 2), .info)
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 1), .debug)
    }

    /// A level added upstream must degrade to informational rather than being
    /// guessed at — and `CONT` genuinely carries no level of its own.
    func testAnUnknownGgmlLevelIsTreatedAsInformational() {
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 5), .info)
        XCTAssertEqual(LlamaNativeLogSeverity(ggmlLevel: 99), .info)
    }

    // MARK: Native log privacy

    /// Section 32. The allowlist keeps the lines a crash investigation needs.
    func testStructuralNativeLinesAreKept() {
        let lines = [
            "ggml_metal_init: found device: Apple A18 Pro GPU",
            "llama_kv_cache_init: KV self size = 96.00 MiB",
            "GGML_ASSERT: ggml-metal.m:1234: !\"unsupported op\"",
            "llama_decode: failed to find a KV slot for the batch",
            "load_tensors: loading model tensors, this can take a while",
        ]
        for line in lines {
            XCTAssertNotNil(LlamaNativeLogSanitizer.sanitize(line), line)
        }
    }

    /// The half that matters more. llama.cpp is not written to this app's
    /// privacy rules, and at high verbosity some builds print prompt fragments.
    func testLinesThatCouldCarryUserTextAreDropped() {
        let lines = [
            "prompt: Remind me to call Dr Patel about the results",
            "main: prompt = \"my address is 14 Elm Row\"",
            "token = 'Patel'",
            "detokenized piece: Patel",
            "chat template output: <|im_start|>user hello",
            "user: I keep forgetting my medication",
            "assistant: Sure, I will remind you at six",
        ]
        for line in lines {
            XCTAssertNil(LlamaNativeLogSanitizer.sanitize(line), line)
        }
    }

    /// A line has to name something structural to be kept; unrecognised chatter
    /// is dropped rather than kept on the assumption it is harmless. The cost of
    /// discarding a harmless line is far lower than the converse.
    func testAnUnrecognisedLineIsDropped() {
        XCTAssertNil(LlamaNativeLogSanitizer.sanitize("......................."))
        XCTAssertNil(LlamaNativeLogSanitizer.sanitize("   "))
    }

    /// llama.cpp prints long tables at load time and one of them would dominate
    /// a session file.
    func testALongNativeLineIsTruncated() throws {
        let long = "llama_model_loader: tensor " + String(repeating: "x", count: 4000)
        let sanitized = try XCTUnwrap(LlamaNativeLogSanitizer.sanitize(long))
        XCTAssertLessThanOrEqual(sanitized.count, LlamaNativeLogSanitizer.maximumLength)
    }

    // MARK: The bridge

    func testTheBridgeForwardsAKeptLineToTheSink() {
        let sink = RecordingDiagnosticSink()
        LlamaNativeLogBridge.install(sink)
        defer { LlamaNativeLogBridge.uninstall() }

        LlamaNativeLogBridge.deliver(
            levelValue: 4, text: "llama_decode: invalid batch, n_tokens is 0"
        )

        let recorded = sink.snapshot()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.name, .nativeLog)
        XCTAssertEqual(recorded.first?.level, .error)
        XCTAssertEqual(recorded.first?.metadata[.nativeLogLevel], .text("error"))
    }

    /// Section 31: a warning or an error is part of the crash trail and is not
    /// subject to the verbose setting, so it is recorded at a level the writer
    /// always persists. Informational chatter is not.
    func testWarningsAndErrorsOutrankInformationalChatter() {
        let sink = RecordingDiagnosticSink()
        LlamaNativeLogBridge.install(sink)
        defer { LlamaNativeLogBridge.uninstall() }

        LlamaNativeLogBridge.deliver(levelValue: 3, text: "llama_context: n_batch is too large")
        LlamaNativeLogBridge.deliver(levelValue: 2, text: "load_tensors: buffer size = 1 MiB")

        let recorded = sink.snapshot()
        // Counted before indexing: a short array here used to take the whole
        // test process down with an out-of-range trap, which hides every test
        // that would have run after it.
        guard recorded.count == 2 else {
            return XCTFail("expected two recorded lines, got \(recorded.count)")
        }
        XCTAssertEqual(recorded[0].level, .warning)
        XCTAssertEqual(recorded[1].level, .debug)
    }

    /// The regression that made this filter worth testing.
    ///
    /// `"text:"` is a substring of `"context:"`, so a plain containment check
    /// dropped every `llama_context:` line — a large share of exactly the output
    /// a decode investigation needs, discarded silently.
    func testContextLinesAreNotMistakenForPromptText() throws {
        let lines = [
            "llama_context: n_batch is too large for this model",
            "llama_context: KV self size = 96.00 MiB",
            "llama_new_context_with_model: compute buffer size = 164.00 MiB",
        ]
        for line in lines {
            XCTAssertNotNil(LlamaNativeLogSanitizer.sanitize(line), line)
        }
    }

    /// The other half of the same boundary rule: an underscore is a boundary,
    /// because llama.cpp names things `n_token` and that line must still go.
    func testAnUnderscorePrefixedForbiddenTopicIsStillCaught() {
        XCTAssertNil(LlamaNativeLogSanitizer.sanitize("batch: n_token = 'medication'"))
        XCTAssertNil(LlamaNativeLogSanitizer.sanitize("context: prompt: call the clinic"))
    }

    /// The sanitizer runs before the sink, not after — so a dropped line never
    /// reaches the thing that writes files.
    func testAForbiddenLineNeverReachesTheSink() {
        let sink = RecordingDiagnosticSink()
        LlamaNativeLogBridge.install(sink)
        defer { LlamaNativeLogBridge.uninstall() }

        LlamaNativeLogBridge.deliver(levelValue: 2, text: "prompt: pick up the prescription")

        XCTAssertTrue(sink.snapshot().isEmpty)
    }

    /// Uninstalling stops the recording. The C callback deliberately stays
    /// installed — handing llama.cpp back its stderr default would put
    /// prompt-derived text in the system log — but nothing is kept.
    func testUninstallingStopsRecording() {
        let sink = RecordingDiagnosticSink()
        LlamaNativeLogBridge.install(sink)
        LlamaNativeLogBridge.uninstall()

        LlamaNativeLogBridge.deliver(levelValue: 4, text: "ggml_metal: assert failed")

        XCTAssertTrue(sink.snapshot().isEmpty)
    }

    // MARK: The minimal harness

    /// Section 36. The test string is a constant in the source, so there is no
    /// path by which user content could reach the minimal decode.
    func testTheMinimalHarnessPromptIsAFixedConstant() {
        XCTAssertEqual(CanonicalMinimalDecodeHarness.diagnosticPrompt, "Hello")
    }

    /// Sections 37 and 38: small, CPU-only, and large enough to be a valid
    /// context rather than a second failure mode.
    func testTheMinimalHarnessUsesASmallSafeContext() {
        XCTAssertEqual(CanonicalMinimalDecodeHarness.contextLength, 256)
        XCTAssertEqual(CanonicalMinimalDecodeHarness.batchSize, 64)
        XCTAssertLessThanOrEqual(
            CanonicalMinimalDecodeHarness.batchSize,
            CanonicalMinimalDecodeHarness.contextLength
        )
    }

    /// Section 43. Neither outcome may be phrased as a diagnosis, and a build
    /// with no runtime says so rather than reporting a failure it never ran.
    func testTheMinimalOutcomeSummariesDoNotClaimACause() {
        let outcomes: [MinimalDecodeOutcome] = [
            .succeeded(tokenCount: 3, elapsedMs: 41),
            .failed(stage: .minimalPromptDecode, reason: "The batch could not be allocated."),
            .unavailable,
        ]
        for outcome in outcomes {
            let summary = outcome.summary.lowercased()
            XCTAssertFalse(summary.contains("out of memory"), outcome.summary)
            XCTAssertFalse(summary.contains("metal is"), outcome.summary)
            XCTAssertFalse(summary.contains("probably"), outcome.summary)
        }
        XCTAssertTrue(MinimalDecodeOutcome.succeeded(tokenCount: 1, elapsedMs: 1).didSucceed)
        XCTAssertFalse(MinimalDecodeOutcome.unavailable.didSucceed)
    }

    // MARK: The export

    /// Section 44. The whole previous log, not a summary of it — a reader who
    /// only gets the conclusion cannot check the conclusion.
    func testTheExportContainsEveryEventOfThePreviousSession() {
        let previousID = LocalInferenceSessionID(rawValue: "previous")
        var events: [LocalInferenceDiagnosticEvent] = []
        for index in 1...41 {
            events.append(
                LocalInferenceDiagnosticEvent(
                    appSessionID: previousID,
                    sequence: index,
                    timestamp: Date(timeIntervalSince1970: 1_781_078_400 + Double(index)),
                    elapsed: Double(index),
                    level: .info,
                    category: .runtime,
                    type: index == 41 ? .enter : .info,
                    name: index == 41 ? .stage : .runtimeConfiguration,
                    stage: index == 41 ? .promptDecode : nil,
                    operationID: index == 41
                        ? LocalInferenceOperationID(rawValue: "OP") : nil,
                    metadata: .empty
                )
            )
        }

        let report = LocalInferenceDiagnosticReport.text(
            header: header(),
            recovery: nil,
            previousSession: LocalInferenceDecodedSession(
                events: events, unreadableLineCount: 0
            ),
            session: LocalInferenceDecodedSession(events: [], unreadableLineCount: 0),
            sessionID: LocalInferenceSessionID(rawValue: "current"),
            writerFailure: nil
        )

        XCTAssertTrue(report.contains("Full previous event log (41)"))
        // The first event as well as the last: truncating to the tail is the
        // failure mode this section names.
        XCTAssertTrue(report.contains("000001"))
        XCTAssertTrue(report.contains("000041 "))
        XCTAssertTrue(report.contains("ENTER prompt_decode"))
    }

    /// The preflight block travels with the conclusion it supports, rather than
    /// several hundred lines away from it.
    ///
    /// Recovered from real events rather than constructed, so this covers the
    /// summarizer lifting the preflight out of the crashing session's own log as
    /// well as the report printing it.
    func testTheExportPrintsThePreviousDecodePreflight() {
        let previousID = LocalInferenceSessionID(rawValue: "previous")
        let preflight = LocalInferenceMetadata()
            .setting(.origin, "assistant_chat")
            .setting(.batchNTokens, 137)
            .setting(.actualContextSize, 2048)
        let events = [
            LocalInferenceDiagnosticEvent(
                appSessionID: previousID,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_078_400),
                elapsed: 1,
                level: .info,
                category: .runtime,
                type: .info,
                name: .decodePreflight,
                stage: .promptDecode,
                operationID: nil,
                metadata: preflight
            ),
            LocalInferenceDiagnosticEvent(
                appSessionID: previousID,
                sequence: 2,
                timestamp: Date(timeIntervalSince1970: 1_781_078_401),
                elapsed: 2,
                level: .error,
                category: .runtime,
                type: .enter,
                name: .stage,
                stage: .promptDecode,
                operationID: LocalInferenceOperationID(rawValue: "OP"),
                metadata: preflight
            ),
        ]
        let recovery = LocalInferenceSessionRecovery.summarize(
            LocalInferenceDecodedSession(events: events, unreadableLineCount: 0),
            sessionID: previousID,
            endedAt: Date(timeIntervalSince1970: 1_781_078_500)
        )
        XCTAssertEqual(recovery.origin, "assistant_chat")
        XCTAssertNotNil(recovery.decodePreflight)

        let report = LocalInferenceDiagnosticReport.text(
            header: header(),
            recovery: recovery,
            previousSession: nil,
            session: LocalInferenceDecodedSession(events: [], unreadableLineCount: 0),
            sessionID: LocalInferenceSessionID(rawValue: "current"),
            writerFailure: nil
        )

        XCTAssertTrue(report.contains("Previous decode preflight"))
        XCTAssertTrue(report.contains("batchNTokens=137"))
        XCTAssertTrue(report.contains("Origin: assistant_chat"))
    }

    /// Section 11. Token identifiers are numbers and nothing detokenizes them,
    /// but "thousands of IDs" is explicitly not wanted.
    func testTheLoggedTokenIdentifierSummaryIsBounded() {
        XCTAssertLessThanOrEqual(LlamaDecodeBatchLimits.loggedTokenIDLimit, 16)
    }

    private func header() -> LocalInferenceReportHeader {
        LocalInferenceReportHeader(
            appVersion: "1.0",
            buildNumber: "10",
            osVersion: "26.6",
            deviceModel: "iPhone17,1",
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            generatedAt: Date(timeIntervalSince1970: 1_781_078_500)
        )
    }
}

/// A sink that keeps what it was handed, on any thread.
///
/// `NSLock` rather than an actor: the real callback is a C function pointer
/// firing on ggml's worker threads with no async context to await from, and a
/// double that could only be read asynchronously would not model it.
private final class RecordingDiagnosticSink: LocalInferenceDiagnosticSink, @unchecked Sendable {

    struct Entry {
        var name: LocalInferenceEventName
        var type: LocalInferenceEventType
        var level: LocalInferenceDiagnosticLevel
        var stage: LocalInferenceStage?
        var metadata: LocalInferenceMetadata
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    let isVerbose = true

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func record(
        _ name: LocalInferenceEventName,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage?,
        metadata: LocalInferenceMetadata
    ) {
        lock.lock()
        entries.append(
            Entry(name: name, type: type, level: level, stage: stage, metadata: metadata)
        )
        lock.unlock()
    }

    func criticalEnter(
        _ stage: LocalInferenceStage,
        metadata: LocalInferenceMetadata
    ) -> LocalInferenceOperationID {
        record(
            .stage, type: .enter, level: .error, category: .runtime,
            stage: stage, metadata: metadata
        )
        return LocalInferenceOperationID(rawValue: "TEST")
    }

    func criticalExit(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {
        record(
            .stage, type: .exit, level: .error, category: .runtime,
            stage: stage, metadata: metadata
        )
    }

    func criticalFailure(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {
        record(
            .stage, type: .error, level: .error, category: .runtime,
            stage: stage, metadata: metadata
        )
    }
}
