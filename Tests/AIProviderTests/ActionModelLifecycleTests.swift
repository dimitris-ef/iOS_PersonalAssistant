import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The dedicated action model's own life: selected, loaded, unloaded, swapped,
/// and independent of the chat model at every step.
///
/// ## The architecture these protect
///
/// Part 1 separated the *decision* — which model interprets an action — from
/// the chat model. Part 3 separates the *model*. What has to be true now is
/// stronger than "the action path exists": the two models have to be able to be
/// different models, in different states, changed independently, without either
/// one reaching into the other's runtime.
final class ActionModelLifecycleTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_788_175_200)
    private static let athens = TimeZone(identifier: "Europe/Athens")!

    private var store: LocalModelStore!

    override func setUp() {
        super.setUp()
        store = LocalModelStore.temporary()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        store = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func descriptor(
        _ id: AIModelIdentifier,
        architecture: String = "qwen3",
        parameters: Int64 = 500_000_000
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: "Model \(id.rawValue)",
            architecture: architecture,
            parameterCount: parameters,
            quantization: .q4KM,
            fileSizeBytes: 400_000_000,
            downloadURL: URL(string: "https://example.invalid/\(id.rawValue).gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024,
            toolSupport: .supported,
            chatTemplate: .chatML
        )
    }

    private struct Harness {
        let host: ActionModelHost
        let repositories: AssistantRepositories
        let actionRuntime: MockLocalModelRuntime
        let chatRuntime: MockLocalModelRuntime
        let manager: LocalModelManager
    }

    /// Installs `models`, and wires a host whose runtime is **not** the chat
    /// runtime — which is the arrangement the app uses and the one section 17
    /// requires.
    private func makeHarness(
        installing models: [LocalModelDescriptor],
        selectedAction: AIModelIdentifier? = nil,
        selectedChat: AIModelIdentifier? = nil,
        actionRuntime: MockLocalModelRuntime = MockLocalModelRuntime()
    ) async throws -> Harness {
        let repositories = AssistantRepositories.ephemeral()
        try store.prepareDirectory()
        for model in models {
            try GGUFFixture.header().write(to: store.url(forRelativePath: model.suggestedFileName))
            try await repositories.localModels.save(
                LocalModelRecord(
                    id: model.id,
                    relativePath: model.suggestedFileName,
                    fileSizeBytes: 400_000_000,
                    installedAt: Self.now,
                    architecture: model.architecture,
                    contextLength: 4096
                )
            )
        }
        try await repositories.settings.update(
            AssistantSettings(
                selectedLocalModelID: selectedChat,
                actionModel: ActionModelConfiguration(selectedModelID: selectedAction)
            )
        )

        let chatRuntime = MockLocalModelRuntime()
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: models),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: chatRuntime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: Self.now)
        )
        let host = ActionModelHost(
            manager: manager,
            settings: repositories.settings,
            runtime: actionRuntime,
            dateProvider: FixedDateProvider(now: Self.now, timeZone: Self.athens)
        )
        return Harness(
            host: host,
            repositories: repositories,
            actionRuntime: actionRuntime,
            chatRuntime: chatRuntime,
            manager: manager
        )
    }

    private func request(_ text: String) -> ActionModelRequest {
        ActionModelRequest(
            userRequest: text,
            now: Self.now,
            timeZoneIdentifier: Self.athens.identifier,
            detectedCategory: .reminder
        )
    }

    private static let reminderEnvelope = """
        {"intent":"reminder.create","arguments":\
        {"title":"change bottles","timeExpression":"in 10 minutes"}}
        """

    // MARK: Independence — sections 2 and 55

    func testTheChatAndActionSelectionsAreDifferentSettings() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("chat-a"), descriptor("action-b")],
            selectedAction: "action-b",
            selectedChat: "chat-a"
        )

        // Change the chat model. The action model is untouched.
        var settings = try await harness.repositories.settings.settings()
        settings.selectedLocalModelID = "chat-c"
        try await harness.repositories.settings.update(settings)

        var configuration = await harness.host.configuration()
        XCTAssertEqual(configuration.selectedModelID, "action-b")

        // Change the action model. The chat model is untouched.
        try await harness.host.select("action-d")
        settings = try await harness.repositories.settings.settings()
        XCTAssertEqual(settings.selectedLocalModelID, "chat-c")
        configuration = await harness.host.configuration()
        XCTAssertEqual(configuration.selectedModelID, "action-d")
    }

    /// Section 62. The selection survives everything being rebuilt around it,
    /// and comes back *unloaded* — the one thing that must not be persisted.
    func testTheSelectionPersistsAndComesBackUnloaded() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: nil
        )
        try await harness.host.select("action-b")

        // A fresh host over the same settings: the same thing a relaunch does.
        let reopened = ActionModelHost(
            manager: harness.manager,
            settings: harness.repositories.settings,
            runtime: MockLocalModelRuntime()
        )
        let configuration = await reopened.configuration()
        XCTAssertEqual(configuration.selectedModelID, "action-b")
        let state = await reopened.runtimeState()
        XCTAssertEqual(state, .unloaded)
    }

    // MARK: Lazy loading — sections 12, 58 and 59

    func testTheModelIsUnloadedUntilTheFirstRequest() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )

        let before = await harness.host.runtimeState()
        XCTAssertEqual(before, .unloaded)
        let loadsBefore = await harness.actionRuntime.loadCount
        XCTAssertEqual(loadsBefore, 0, "nothing should load until something needs it")

        await harness.actionRuntime.alwaysRespond(.raw(Self.reminderEnvelope))
        _ = try await harness.host.generate(
            request: request("Remind me in 10 minutes."), constraints: .universal
        )

        let after = await harness.host.runtimeState()
        XCTAssertEqual(after, .loaded("action-b"))
        let loadsAfter = await harness.actionRuntime.loadCount
        XCTAssertEqual(loadsAfter, 1)
    }

    func testASecondRequestDoesNotReload() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        await harness.actionRuntime.alwaysRespond(.raw(Self.reminderEnvelope))

        _ = try await harness.host.generate(
            request: request("Remind me in 10 minutes."), constraints: .universal
        )
        _ = try await harness.host.generate(
            request: request("Remind me in 20 minutes."), constraints: .universal
        )

        let loads = await harness.actionRuntime.loadCount
        XCTAssertEqual(loads, 1, "an already-loaded model must not be reloaded")
    }

    // MARK: Load, unload and switching — sections 14, 33 and 63

    func testUnloadingTheActionModelLeavesTheChatModelAlone() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b"), descriptor("chat-a")],
            selectedAction: "action-b",
            selectedChat: "chat-a"
        )
        _ = try await harness.manager.load("chat-a")
        try await harness.host.ensureLoaded()

        await harness.host.unload()

        let actionState = await harness.host.runtimeState()
        XCTAssertEqual(actionState, .unloaded)
        // The chat runtime still holds its model: they are different instances,
        // so there is nothing the action host *could* have unloaded.
        let chatLoaded = await harness.chatRuntime.loadedModel()
        XCTAssertEqual(chatLoaded?.modelID, "chat-a")
        let chatUnloads = await harness.chatRuntime.unloadCount
        XCTAssertEqual(chatUnloads, 0)
    }

    /// Section 64. Switching unloads the old one and does not load the new one.
    func testSwitchingActionModelsUnloadsTheOldOneAndDoesNotLoadTheNew() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-a"), descriptor("action-b")],
            selectedAction: "action-a"
        )
        try await harness.host.ensureLoaded()
        let loadsAfterFirst = await harness.actionRuntime.loadCount
        XCTAssertEqual(loadsAfterFirst, 1)

        try await harness.host.select("action-b")

        let unloads = await harness.actionRuntime.unloadCount
        XCTAssertEqual(unloads, 1, "the old action model must be released")
        let state = await harness.host.runtimeState()
        XCTAssertEqual(state, .unloaded, "the new one waits until it is needed")
        let loads = await harness.actionRuntime.loadCount
        XCTAssertEqual(loads, 1, "selecting must not load")

        let configuration = await harness.host.configuration()
        XCTAssertEqual(configuration.selectedModelID, "action-b")
    }

    /// Section 75. Idle plus memory pressure is a safe unload; mid-generation
    /// is not, and the guard is what makes the difference.
    func testAMemoryWarningUnloadsAnIdleActionModel() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        try await harness.host.ensureLoaded()

        await harness.host.unloadIfIdle()

        let state = await harness.host.runtimeState()
        XCTAssertEqual(state, .unloaded)
    }

    // MARK: Failing safely — sections 60, 61 and 65

    func testWithNoModelSelectedTheActionPathIsUnavailable() async throws {
        let harness = try await makeHarness(installing: [descriptor("action-b")])

        let availability = await harness.host.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, "No action model is selected.")

        do {
            _ = try await harness.host.generate(
                request: request("Remind me in 10 minutes."), constraints: .universal
            )
            XCTFail("expected a refusal")
        } catch let error as ActionModelError {
            XCTAssertEqual(error.symbol, "backendUnavailable")
        }
        let loads = await harness.actionRuntime.loadCount
        XCTAssertEqual(loads, 0, "nothing may be loaded for a request that cannot run")
    }

    /// Section 61: an incompatible model is refused before any native call.
    func testAnIncompatibleModelIsRefusedWithoutLoading() async throws {
        let harness = try await makeHarness(
            // No architecture in the record means the header never parsed.
            installing: [descriptor("action-b", architecture: "")],
            selectedAction: "action-b"
        )

        let status = await harness.host.status()
        XCTAssertFalse(status.compatibility.isUsable)
        XCTAssertEqual(status.unavailableReason, ActionModelIncompatibility.invalidModelFile.message)

        do {
            _ = try await harness.host.generate(
                request: request("Remind me in 10 minutes."), constraints: .universal
            )
            XCTFail("expected a refusal")
        } catch let error as ActionModelError {
            XCTAssertEqual(error.symbol, "modelIncompatible")
        }
        let loads = await harness.actionRuntime.loadCount
        XCTAssertEqual(loads, 0)
    }

    /// Sections 35 and 65: a selection pointing at a file that is not there is
    /// a reportable state, not a crash — and it does not disturb the chat side.
    func testADeletedActionModelFailsSafely() async throws {
        let model = descriptor("action-b")
        let harness = try await makeHarness(
            installing: [model], selectedAction: "action-b", selectedChat: "chat-a"
        )

        try FileManager.default.removeItem(
            at: store.url(forRelativePath: model.suggestedFileName)
        )
        try await harness.repositories.localModels.delete(model.id)

        let status = await harness.host.status()
        XCTAssertFalse(status.isUsable)
        XCTAssertEqual(status.unavailableReason, ActionModelIncompatibility.modelMissing.message)

        let settings = try await harness.repositories.settings.settings()
        XCTAssertEqual(settings.selectedLocalModelID, "chat-a", "the chat model is untouched")
    }

    /// Section 13: a load that fails is a failed action request, full stop.
    func testALoadFailureDoesNotFallBackToAnythingElse() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.setLoadBehaviour(.fail(.loadFailed(reason: "out of memory")))
        let harness = try await makeHarness(
            installing: [descriptor("action-b")],
            selectedAction: "action-b",
            actionRuntime: runtime
        )

        do {
            _ = try await harness.host.generate(
                request: request("Remind me in 10 minutes."), constraints: .universal
            )
            XCTFail("expected a refusal")
        } catch let error as ActionModelError {
            XCTAssertEqual(error.symbol, "loadFailed")
        }
        let state = await harness.host.runtimeState()
        guard case .failed = state else {
            return XCTFail("a failed load should be visible in the state")
        }
    }

    // MARK: Context and generation policy — sections 73 and 74

    /// Section 73. The action model is opened with the action context, not the
    /// chat model's — asserted on the request the runtime actually received.
    func testTheActionModelUsesItsOwnShortContext() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        try await harness.host.ensureLoaded()

        let loadRequest = await harness.actionRuntime.lastLoadRequest
        let received = try XCTUnwrap(loadRequest)
        XCTAssertEqual(received.contextLength, ActionInferenceProductionPolicy.production.contextLength)
        XCTAssertEqual(received.contextLength, 1024)
        // Emphatically not the chat model's, which the manager sizes to the
        // device and which is larger on every tier.
        XCTAssertLessThan(
            received.contextLength,
            LocalInferenceConfiguration.forDevice(FixedDeviceResources.largePhone).contextLength
        )
    }

    /// Section 74, and section 72: a short bounded generation, with the GPU
    /// requested by the production policy.
    func testTheGenerationLimitIsShortAndTheGPUIsRequested() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        await harness.actionRuntime.alwaysRespond(.raw(Self.reminderEnvelope))
        _ = try await harness.host.generate(
            request: request("Remind me in 10 minutes."), constraints: .universal
        )

        let loadRequest = await harness.actionRuntime.lastLoadRequest
        XCTAssertEqual(loadRequest?.gpuOffloadRequested, true)

        let options = await harness.actionRuntime.lastOptions
        let used = try XCTUnwrap(options)
        XCTAssertLessThanOrEqual(used.maximumOutputTokens, 256)
        XCTAssertGreaterThanOrEqual(used.maximumOutputTokens, 64)
        // Section 26: deterministic sampling for an extraction task.
        XCTAssertEqual(used.temperature, 0)
        // And constrained, which is Part 2's rule surviving into Part 3.
        XCTAssertNotNil(used.grammar)
    }

    /// Section 72 stated on the policy itself: production means GPU on and
    /// CPU-only off, with no diagnostic residue inherited.
    func testTheProductionPolicyAsksForTheGPU() {
        let policy = ActionInferenceProductionPolicy.production
        XCTAssertTrue(policy.requestsGPUOffload)
        XCTAssertTrue(policy.isProductionProfile(with: .none))

        let request = policy.loadRequest(
            modelID: "m", fileURL: URL(fileURLWithPath: "/tmp/m.gguf"), overrides: .none
        )
        XCTAssertTrue(request.gpuOffloadRequested)

        // Section 28: an explicit CPU-only override still applies.
        let handicapped = policy.loadRequest(
            modelID: "m",
            fileURL: URL(fileURLWithPath: "/tmp/m.gguf"),
            overrides: LocalInferenceDiagnosticOverrides(forceCPUOnly: true)
        )
        XCTAssertFalse(handicapped.gpuOffloadRequested)
    }

    // MARK: Context isolation — sections 66 and 67

    /// Section 66 and 19. The action model gets the sentence and the protocol.
    /// A conversation happening in the chat model is not something it can see —
    /// there is no field on `ActionModelRequest` that could carry one, and the
    /// prompt it receives is two turns.
    func testTheActionModelNeverSeesConversationHistory() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        await harness.actionRuntime.alwaysRespond(.raw(Self.reminderEnvelope))

        _ = try await harness.host.generate(
            request: request("Remind me in 10 minutes to change bottles."),
            constraints: .universal
        )

        let prompt = try XCTUnwrap(await harness.actionRuntime.lastPrompt)
        XCTAssertEqual(prompt.turns.count, 2, "system instructions and the sentence")
        let text = prompt.turns.map(\.content).joined(separator: "\n").lowercased()
        XCTAssertTrue(text.contains("remind me in 10 minutes to change bottles."))
        for forbidden in ["createreminder", "relatedtaskid", "eventid", "listname"] {
            XCTAssertFalse(text.contains(forbidden), "the action prompt showed \(forbidden)")
        }
    }

    // MARK: The produced action still goes downstream — section 70

    func testTheProducedActionIsTheExistingSemanticAction() async throws {
        let harness = try await makeHarness(
            installing: [descriptor("action-b")], selectedAction: "action-b"
        )
        await harness.actionRuntime.alwaysRespond(.raw(Self.reminderEnvelope))

        let produced = try await harness.host.generate(
            request: request("Remind me in 10 minutes to change bottles."),
            constraints: .universal
        )

        guard case .action(let action) = produced else {
            return XCTFail("expected a semantic action")
        }
        XCTAssertEqual(action.intent, .reminderCreate)
        XCTAssertEqual(action[.title], "change bottles")
        XCTAssertEqual(action[.timeExpression], "in 10 minutes")
    }
}
