import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The diagnostic handicaps, and the export they end up described in.
final class LocalInferenceDiagnosticOverridesTests: XCTestCase {

    private var base: LocalInferenceConfiguration {
        LocalInferenceConfiguration.forDevice(FixedDeviceResources.largePhone)
    }

    // MARK: Section 115 — mapping into a runtime configuration

    func testNoOverridesLeaveTheDeviceConfigurationUntouched() {
        XCTAssertEqual(LocalInferenceDiagnosticOverrides.none.apply(to: base), base)
        XCTAssertFalse(LocalInferenceDiagnosticOverrides.none.isActive)
    }

    func testConservativeContextShrinksTheContextAndTheBatches() {
        let configuration = LocalInferenceDiagnosticOverrides(conservativeContext: true)
            .apply(to: base)

        XCTAssertLessThanOrEqual(
            configuration.contextLength,
            LocalInferenceDiagnosticOverrides.conservativeContextLength
        )
        XCTAssertLessThan(configuration.contextLength, base.contextLength)
        XCTAssertLessThanOrEqual(configuration.batchSize, configuration.contextLength)
    }

    func testConservativeBatchShrinksBothBatchNumbers() {
        let configuration = LocalInferenceDiagnosticOverrides(conservativeBatch: true)
            .apply(to: base)

        XCTAssertLessThanOrEqual(
            configuration.batchSize, LocalInferenceConfiguration.conservative.batchSize
        )
        XCTAssertLessThanOrEqual(
            configuration.microBatchSize, LocalInferenceConfiguration.conservative.microBatchSize
        )
        XCTAssertLessThan(configuration.microBatchSize, base.microBatchSize)
    }

    func testSingleThreadModeMeansOneThread() {
        XCTAssertEqual(
            LocalInferenceDiagnosticOverrides(threadMode: .single).apply(to: base).threadCount, 1
        )
        XCTAssertLessThanOrEqual(
            LocalInferenceDiagnosticOverrides(threadMode: .low).apply(to: base).threadCount, 2
        )
        XCTAssertEqual(
            LocalInferenceDiagnosticOverrides(threadMode: .automatic).apply(to: base).threadCount,
            base.threadCount
        )
    }

    /// Section 71. Two switches that can disagree about the same hardware is a
    /// configuration nobody can reason about, so CPU-only wins outright.
    func testCPUOnlyOverridesTheGPUSwitchRatherThanContradictingIt() {
        let contradictory = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true, gpuOffloadEnabled: true
        )
        XCTAssertFalse(contradictory.wantsGPUOffload)

        XCTAssertTrue(
            LocalInferenceDiagnosticOverrides(forceCPUOnly: false, gpuOffloadEnabled: true)
                .wantsGPUOffload
        )
        XCTAssertFalse(
            LocalInferenceDiagnosticOverrides(forceCPUOnly: false, gpuOffloadEnabled: false)
                .wantsGPUOffload
        )
    }

    /// Two overrides that are each individually sane must not compose into a
    /// configuration that is not — a micro batch larger than the batch it feeds
    /// allocates a buffer it can never fill.
    func testOverridesCannotComposeIntoAnInvalidConfiguration() {
        for overrides in [
            LocalInferenceDiagnosticOverrides(conservativeContext: true, conservativeBatch: true),
            LocalInferenceDiagnosticOverrides(conservativeContext: true),
            LocalInferenceDiagnosticOverrides(conservativeBatch: true, threadMode: .single),
        ] {
            let configuration = overrides.apply(to: base)
            XCTAssertLessThanOrEqual(configuration.microBatchSize, configuration.batchSize)
            XCTAssertLessThanOrEqual(configuration.batchSize, configuration.contextLength)
            XCTAssertGreaterThan(configuration.threadCount, 0)
            XCTAssertGreaterThan(configuration.maximumPromptTokens, 0)
        }
    }

    /// Section 76: turning them off restores the automatic behaviour exactly.
    /// There is no third state needing a reset.
    func testTurningOverridesOffRestoresTheAutomaticConfiguration() {
        let handicapped = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true, conservativeContext: true,
            conservativeBatch: true, threadMode: .single
        )
        XCTAssertNotEqual(handicapped.apply(to: base), base)

        var restored = handicapped
        restored.forceCPUOnly = false
        restored.conservativeContext = false
        restored.conservativeBatch = false
        restored.threadMode = .automatic
        XCTAssertEqual(restored.apply(to: base), base)
    }

    // MARK: Section 75 — they are recorded

    func testActiveOverridesAppearInTheirMetadata() {
        let metadata = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true, conservativeContext: true,
            conservativeBatch: true, threadMode: .single
        ).metadata()

        XCTAssertEqual(metadata[.cpuOnly], .bool(true))
        XCTAssertEqual(metadata[.conservativeContext], .bool(true))
        XCTAssertEqual(metadata[.conservativeBatch], .bool(true))
        XCTAssertEqual(metadata[.threadMode], .text("single"))
        XCTAssertEqual(metadata[.requestedGPUOffload], .bool(false))
    }

    /// They round-trip through `UserDefaults`, which is where the app keeps
    /// them — a decode failure would silently restore full-speed inference
    /// mid-investigation.
    func testOverridesSurviveEncodingAndDecoding() throws {
        let original = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true, gpuOffloadEnabled: false,
            conservativeContext: true, conservativeBatch: false, threadMode: .low
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            LocalInferenceDiagnosticOverrides.self, from: data
        )
        XCTAssertEqual(decoded, original)
    }
}

/// The text a person copies, shares or exports.
final class LocalInferenceDiagnosticReportTests: XCTestCase {

    private let session = LocalInferenceSessionID(rawValue: "abcdef01-2345")

    private func event(
        _ sequence: Int,
        type: LocalInferenceEventType,
        name: LocalInferenceEventName = .stage,
        stage: LocalInferenceStage? = nil,
        metadata: LocalInferenceMetadata = .empty
    ) -> LocalInferenceDiagnosticEvent {
        LocalInferenceDiagnosticEvent(
            appSessionID: session,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_781_078_400),
            elapsed: Double(sequence) / 2,
            category: .runtime,
            type: type,
            name: name,
            stage: stage,
            operationID: LocalInferenceOperationID(rawValue: "OP1"),
            metadata: metadata
        )
    }

    private var header: LocalInferenceReportHeader {
        LocalInferenceReportHeader(
            appVersion: "1.0", buildNumber: "142", osVersion: "26.1",
            deviceModel: "iPhone17,1", physicalMemoryBytes: 8 * .gigabyte,
            generatedAt: Date(timeIntervalSince1970: 1_781_078_400)
        )
    }

    /// Section 109.
    func testTheExportCarriesTheSummaryAndTheEvents() {
        let events = [
            event(1, type: .info, name: .appLaunch),
            event(2, type: .enter, stage: .modelLoad),
            event(
                3, type: .exit, stage: .modelLoad,
                metadata: LocalInferenceMetadata().setting(.actualContextSize, 2048)
            ),
            event(4, type: .enter, stage: .contextCreate),
        ]
        let report = LocalInferenceDiagnosticReport.text(
            header: header,
            recovery: nil,
            session: LocalInferenceDecodedSession(events: events, unreadableLineCount: 0),
            sessionID: session,
            writerFailure: nil
        )

        XCTAssertTrue(report.contains("MetisAI Local AI Diagnostic Report"))
        XCTAssertTrue(report.contains("App version: 1.0"))
        XCTAssertTrue(report.contains("Build: 142"))
        XCTAssertTrue(report.contains("iOS: 26.1"))
        XCTAssertTrue(report.contains("iPhone17,1"))
        XCTAssertTrue(report.contains(session.rawValue))
        XCTAssertTrue(report.contains("APP_LAUNCH"))
        XCTAssertTrue(report.contains("ENTER model_load"))
        XCTAssertTrue(report.contains("EXIT model_load"))
        XCTAssertTrue(report.contains("ENTER context_create"))
        XCTAssertTrue(report.contains("actualContextSize=2048"))
    }

    func testTheExportIncludesThePreviousSessionSummary() {
        let recovery = LocalInferenceRecoverySummary(
            sessionID: LocalInferenceSessionID(rawValue: "previous"),
            endedAt: Date(timeIntervalSince1970: 1_781_078_000),
            endedCleanly: false,
            enteredLocalInference: true,
            unresolvedStages: [],
            deepestUnresolvedStage: LocalInferenceOpenStage(
                stage: .contextCreate,
                operationID: LocalInferenceOperationID(rawValue: "OP9"),
                sequence: 12,
                timestamp: Date(timeIntervalSince1970: 1_781_078_000),
                metadata: .empty
            ),
            lastCompletedStage: .modelLoad,
            lastEvent: nil,
            eventCount: 12,
            unreadableLineCount: 1,
            modelID: "qwen3-1.7b",
            configuration: nil
        )
        let report = LocalInferenceDiagnosticReport.text(
            header: header,
            recovery: recovery,
            session: LocalInferenceDecodedSession(events: [], unreadableLineCount: 0),
            sessionID: session,
            writerFailure: nil
        )

        XCTAssertTrue(report.contains("Clean shutdown recorded: No"))
        XCTAssertTrue(report.contains("Last successful stage: model_load"))
        XCTAssertTrue(report.contains("ENTER context_create"))
        XCTAssertTrue(report.contains("Unreadable log lines: 1"))
        // Section 52: the export must not fabricate a termination reason.
        XCTAssertTrue(report.contains("not available to the app"))
    }

    func testTheExportFileNameIsTimestampedAndTyped() {
        let name = LocalInferenceDiagnosticReport.exportFileName(
            at: Date(timeIntervalSince1970: 1_781_078_400)
        )
        XCTAssertTrue(name.hasPrefix("metis-local-diagnostics-"))
        XCTAssertTrue(name.hasSuffix(".jsonl"))
        XCTAssertFalse(name.contains(" "), "a file name with a space is a share sheet problem")
    }

    /// The JSONL export round-trips, so whoever receives one can parse it.
    func testTheJSONLExportCanBeReadBack() {
        let events = [
            event(1, type: .enter, stage: .promptDecode),
            event(
                2, type: .exit, stage: .promptDecode,
                metadata: LocalInferenceMetadata()
                    .setting(.promptTokenCount, 812)
                    .setting(.compiledWithMetal, true)
            ),
        ]
        let data = LocalInferenceDiagnosticReport.jsonl(
            LocalInferenceDecodedSession(events: events, unreadableLineCount: 0)
        )
        let decoded = LocalInferenceDiagnosticCoding.decode(data)

        XCTAssertEqual(decoded.events.count, 2)
        XCTAssertEqual(decoded.events[1].metadata[.promptTokenCount], .int(812))
        XCTAssertEqual(
            decoded.events[1].metadata[.compiledWithMetal], .bool(true),
            "a boolean came back as a number — JSONSerialization hands back NSNumber for both"
        )
    }
}
