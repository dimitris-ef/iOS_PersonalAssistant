import AssistantAI
import AssistantDomain
import AssistantPersistence
import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// What must never reach a diagnostic file.
///
/// The design intent is that these tests are hard to write, because the type
/// system is supposed to make the mistake unexpressible. Where a test here
/// *can* attempt something forbidden, it is going through
/// `init(sanitizing:)` — the one untyped door — which is exactly the door
/// section 84 asks to have guarded.
final class LocalInferencePrivacyTests: XCTestCase {

    /// The marker from section 116. If this string ever appears in a
    /// diagnostic artefact, the privacy design has failed.
    private static let secret = "SUPER_PRIVATE_TEST_TEXT"

    private var store: LocalInferenceDiagnosticStore!

    override func setUp() {
        super.setUp()
        store = .temporary()
        try? store.prepareDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        store = nil
        super.tearDown()
    }

    // MARK: The allowlist

    /// Section 107. The four keys named in the specification, attempted
    /// through the only entry point that accepts arbitrary names.
    func testForbiddenKeysAndTheirValuesAreDropped() {
        let metadata = LocalInferenceMetadata(sanitizing: [
            "prompt": Self.secret,
            "content": Self.secret,
            "response": Self.secret,
            "memory": Self.secret,
            "apiKey": Self.secret,
            "authorization": Self.secret,
            "conversationHistory": Self.secret,
        ])
        XCTAssertTrue(metadata.isEmpty, "a forbidden key survived sanitisation")

        let encoded = LocalInferenceDiagnosticCoding.encodeMetadata(metadata)
        XCTAssertTrue(encoded.isEmpty)
    }

    /// A key nobody thought of is dropped too. The allowlist is a whitelist,
    /// not a blocklist, so the default for anything unrecognised is "no".
    func testAnUnknownKeyIsDroppedEvenWhenItSoundsHarmless() {
        let metadata = LocalInferenceMetadata(sanitizing: [
            "somethingNobodyAnticipated": Self.secret
        ])
        XCTAssertTrue(metadata.isEmpty)
    }

    /// Section 108: the safe counts survive, or the system would be useless.
    func testSafeCountsSurviveSanitisation() {
        let metadata = LocalInferenceMetadata(sanitizing: [
            "characterCount": "1200",
            "tokenCount": "310",
            "messageCount": "8",
            "modelID": "qwen3-1.7b",
            "quantization": "Q4_K_M",
        ])
        XCTAssertEqual(metadata[.characterCount], .text("1200"))
        XCTAssertEqual(metadata[.tokenCount], .text("310"))
        XCTAssertEqual(metadata[.messageCount], .text("8"))
        XCTAssertEqual(metadata[.modelID], .text("qwen3-1.7b"))
    }

    /// Keys that merely *contain* a suspicious word are not collateral damage:
    /// `tokenCount` contains "token" and `messageCount` contains "message", and
    /// both are on the allowlist, so both are fine.
    func testAllowlistedKeysAreNotRejectedForContainingASuspiciousWord() {
        XCTAssertFalse(LocalInferenceRedaction.isForbiddenKey("tokenCount"))
        XCTAssertFalse(LocalInferenceRedaction.isForbiddenKey("messageCount"))
        XCTAssertFalse(LocalInferenceRedaction.isForbiddenKey("tokenizerFamily"))
        XCTAssertTrue(LocalInferenceRedaction.isForbiddenKey("promptText"))
        XCTAssertTrue(LocalInferenceRedaction.isForbiddenKey("bearerToken"))
    }

    /// Free text is capped, because the one string field is where prose would
    /// arrive if an error message ever interpolated user input.
    func testFreeTextIsCappedAndFlattened() {
        let long = String(repeating: "a", count: 5_000)
        let metadata = LocalInferenceMetadata().setting(.errorReason, long + "\nsecond line")
        guard case .text(let stored)? = metadata[.errorReason] else {
            return XCTFail("the reason was not stored")
        }
        XCTAssertLessThanOrEqual(stored.count, LocalInferenceRedaction.maximumTextLength)
        XCTAssertFalse(
            stored.contains("\n"),
            "a newline in a value would split one JSONL record into two lines"
        )
    }

    // MARK: End to end

    /// Section 116, and the test that matters most in this file.
    ///
    /// A real turn: a real `LocalModelProvider`, a real `LocalModelManager`, a
    /// real logger writing to a real file — with the secret marker in the
    /// system prompt, the user's message, the assistant's history and the
    /// model's reply. Then every byte the diagnostic system produced is
    /// searched for it.
    func testNothingFromAConversationReachesTheDiagnosticFile() async throws {
        let modelStore = LocalModelStore.temporary()
        defer { try? FileManager.default.removeItem(at: modelStore.directory) }

        let repositories = AssistantRepositories.ephemeral()
        let descriptor = LocalModelDescriptor(
            id: "model-a",
            displayName: "Model A",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024
        )
        try modelStore.prepareDirectory()
        try GGUFFixture.header().write(
            to: modelStore.url(forRelativePath: descriptor.suggestedFileName)
        )
        try await repositories.localModels.save(
            LocalModelRecord(
                id: descriptor.id,
                relativePath: descriptor.suggestedFileName,
                fileSizeBytes: 1_100_000_000,
                installedAt: Date(timeIntervalSince1970: 1_781_078_400),
                architecture: "qwen3",
                contextLength: 4096
            )
        )
        try await repositories.settings.update(
            AssistantSettings(selectedLocalModelID: descriptor.id)
        )

        let logger = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        let runtime = MockLocalModelRuntime()
        // Even the model's *reply* carries the marker, so a well-meaning
        // "log the output for debugging" would be caught here too.
        await runtime.alwaysRespond(.text("The answer is \(Self.secret)."))

        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [descriptor]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: modelStore,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            diagnostics: logger
        )
        let provider = LocalModelProvider(
            manager: manager, runtime: runtime, diagnostics: logger
        )

        let response = try await provider.respond(
            to: AIRequest(
                systemPrompt: "You are an assistant. Remember: \(Self.secret)",
                messages: [
                    AIMessage(role: .user, content: "Tell me about \(Self.secret)"),
                    AIMessage(role: .assistant, content: "Earlier I said \(Self.secret)"),
                    AIMessage(role: .user, content: Self.secret),
                ]
            )
        )
        // The marker really did travel through the pipeline — otherwise this
        // test would pass for the wrong reason.
        XCTAssertTrue(response.text.contains(Self.secret))

        // 1. The raw file on disk.
        let raw = try Data(contentsOf: store.url(forSession: logger.appSessionID))
        let rawText = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawText.isEmpty, "nothing was logged, so this proves nothing")
        XCTAssertFalse(
            rawText.contains(Self.secret),
            "the conversation reached the diagnostic file"
        )

        // 2. The decoded events.
        let decoded = LocalInferenceDiagnosticCoding.decode(raw)
        for event in decoded.events {
            for (key, value) in event.metadata.values {
                if case .text(let text) = value {
                    XCTAssertFalse(
                        text.contains(Self.secret),
                        "\(key.rawValue) carried conversation content"
                    )
                }
            }
        }

        // 3. The exported report, which is what a person actually shares.
        let report = LocalInferenceDiagnosticReport.text(
            header: LocalInferenceReportHeader(
                appVersion: "1.0", buildNumber: "1", osVersion: "26.0",
                deviceModel: "iPhone17,1", physicalMemoryBytes: 8 * .gigabyte,
                generatedAt: Date()
            ),
            recovery: nil,
            previousSession: nil,
            session: decoded,
            sessionID: logger.appSessionID,
            writerFailure: nil
        )
        XCTAssertFalse(report.contains(Self.secret), "the export leaked the conversation")

        // 4. And the sidecar.
        if let sidecar = try? Data(contentsOf: store.currentStageURL) {
            XCTAssertFalse(String(decoding: sidecar, as: UTF8.self).contains(Self.secret))
        }
    }

    /// The positive half of the same run: it logged something *useful*.
    ///
    /// Without this, a logger that wrote nothing at all would pass every
    /// privacy assertion above with flying colours.
    func testTheSameRunStillRecordsTheStagesThatMatter() async throws {
        let modelStore = LocalModelStore.temporary()
        defer { try? FileManager.default.removeItem(at: modelStore.directory) }

        let repositories = AssistantRepositories.ephemeral()
        let descriptor = LocalModelDescriptor(
            id: "model-a",
            displayName: "Model A",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024
        )
        try modelStore.prepareDirectory()
        try GGUFFixture.header().write(
            to: modelStore.url(forRelativePath: descriptor.suggestedFileName)
        )
        try await repositories.localModels.save(
            LocalModelRecord(
                id: descriptor.id,
                relativePath: descriptor.suggestedFileName,
                fileSizeBytes: 1_100_000_000,
                installedAt: Date(timeIntervalSince1970: 1_781_078_400),
                architecture: "qwen3",
                contextLength: 4096
            )
        )
        try await repositories.settings.update(
            AssistantSettings(selectedLocalModelID: descriptor.id)
        )

        let logger = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Fine."))
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [descriptor]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: modelStore,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            diagnostics: logger
        )
        let provider = LocalModelProvider(
            manager: manager, runtime: runtime, diagnostics: logger
        )

        _ = try await provider.respond(
            to: AIRequest(systemPrompt: "You are an assistant.", messages: [
                AIMessage(role: .user, content: "Hello")
            ])
        )

        let events = store.read(session: logger.appSessionID)?.events ?? []
        XCTAssertTrue(
            events.contains { $0.name == .loadRequested },
            "the load was not recorded"
        )
        XCTAssertTrue(
            events.contains { $0.name == .memoryEstimate },
            "the memory estimate was not recorded"
        )
        XCTAssertTrue(
            events.contains { $0.type == .enter && $0.stage == .promptConstruct },
            "prompt construction has no breadcrumb"
        )
        XCTAssertTrue(
            events.contains { $0.type == .enter && $0.stage == .inference },
            "the inference attempt has no breadcrumb"
        )

        // And it balanced: a successful turn leaves nothing open.
        let summary = LocalInferenceSessionRecovery.summarize(
            LocalInferenceDecodedSession(events: events, unreadableLineCount: 0),
            sessionID: logger.appSessionID,
            endedAt: Date()
        )
        XCTAssertTrue(
            summary.unresolvedStages.isEmpty,
            "a successful turn left \(summary.unresolvedStages.map(\.stage)) open, which "
                + "would be reported as a crash site on the next launch"
        )
    }

    // MARK: Paths

    /// Sections 20 and 86: a log somebody pastes into an email must not carry
    /// their container path.
    func testTheContainerPathIsNeverLogged() async throws {
        let modelStore = LocalModelStore.temporary()
        defer { try? FileManager.default.removeItem(at: modelStore.directory) }

        let repositories = AssistantRepositories.ephemeral()
        let descriptor = LocalModelDescriptor(
            id: "model-a",
            displayName: "Model A",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096
        )
        try modelStore.prepareDirectory()
        try GGUFFixture.header().write(
            to: modelStore.url(forRelativePath: descriptor.suggestedFileName)
        )
        try await repositories.localModels.save(
            LocalModelRecord(
                id: descriptor.id,
                relativePath: descriptor.suggestedFileName,
                fileSizeBytes: 1_100_000_000,
                installedAt: Date(timeIntervalSince1970: 1_781_078_400),
                contextLength: 4096
            )
        )

        let logger = LocalInferenceDiagnosticLogger(store: store, verbose: true)
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [descriptor]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: modelStore,
            runtime: MockLocalModelRuntime(),
            device: FixedDeviceResources.largePhone,
            diagnostics: logger
        )
        _ = try await manager.load(descriptor.id)

        let raw = String(
            decoding: try Data(contentsOf: store.url(forSession: logger.appSessionID)),
            as: UTF8.self
        )
        XCTAssertTrue(raw.contains(descriptor.suggestedFileName), "the file name is useful")
        XCTAssertFalse(
            raw.contains(modelStore.directory.path),
            "the absolute container path reached the log"
        )
    }
}
