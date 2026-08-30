import AIProviderLocal
import AIProviderLocalLlama
import AssistantDomain
import SwiftUI
import UIKit

/// Local AI Diagnostics: what this session did, and where the last one stopped.
///
/// ## What this screen is for
///
/// One question, asked after the app has come back from being killed: *where
/// was it?* Everything else on the screen is context for reading that answer —
/// the model, the context size, the batch numbers, the memory estimate, the
/// thermal state. The log itself is at the bottom because it is the evidence,
/// not the summary.
///
/// ## What it is careful not to say
///
/// Sections 50 and 51. It reports an unmatched ENTER and stops. It never says
/// "out of memory", never says "crash", and says out loud that iOS does not
/// tell an app why its predecessor died. A diagnostic screen that guesses is
/// worse than none, because a wrong guess is followed for days.
struct LocalInferenceDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SessionChoice = .current
    @State private var didCopy = false
    @State private var isConfirmingClear = false
    @State private var shareURL: URL?
    @State private var runtime: LocalRuntimeDiagnostic?

    /// Section 71: which model the minimal test opens, chosen explicitly.
    @State private var installedModels: [LocalModelStatus] = []
    @State private var minimalTestModel: AIModelIdentifier?
    @State private var isConfirmingMinimalTest = false
    @State private var isRunningMinimalTest = false
    /// Section 42. Kept on the screen after the run, because the point of the
    /// test is comparing its answer against what the real path did.
    @State private var minimalOutcome: MinimalDecodeOutcome?

    private var centre: LocalInferenceDiagnosticsCentre { model.localDiagnostics }

    enum SessionChoice: Hashable {
        case current
        case previous
    }

    var body: some View {
        List {
            previousSessionSection
            summarySection
            configurationSection
            decodeSnapshotSection
            nativeLogSection
            minimalTestSection
            advancedSection
            logSection
            actionSection
        }
        .navigationTitle("Local AI Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            runtime = await model.localRuntimeDiagnostic()
            installedModels = await model.localModels.statuses()
                .filter { $0.lifecycle.isInstalled }
            if minimalTestModel == nil {
                minimalTestModel = installedModels.first { $0.isSelected }?.id
                    ?? installedModels.first?.id
            }
        }
        .confirmationDialog(
            "Run a minimal native decode test?",
            isPresented: $isConfirmingMinimalTest,
            titleVisibility: .visible
        ) {
            Button("Run Test") { runMinimalTest() }
            Button("Cancel", role: .cancel) { isConfirmingMinimalTest = false }
        } message: {
            // Section 69. It unloads the resident model and opens its own, and
            // it can take the app down with it — that is what it is testing.
            Text(
                "This unloads any model currently in memory, opens the chosen model "
                    + "on its own and performs a single decode of a fixed test word. "
                    + "If the on-device runtime is crashing, this may end the app. "
                    + "The breadcrumb is written before the call, so the log survives "
                    + "either way."
            )
        }
        .confirmationDialog(
            "Clear diagnostic logs?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) { centre.clearLogs() }
            Button("Cancel", role: .cancel) { isConfirmingClear = false }
        } message: {
            // Section 66, said out loud: "clear" next to a crash log reasonably
            // makes people wonder what else goes with it.
            Text(
                "Deletes the diagnostic files only. Your models, conversations, "
                    + "memories, tasks and settings are not affected."
            )
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareLink(item: shareURL) { Text("Share Diagnostic File") }
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: The previous session

    /// Section 55. Prominent, first, and worded so nobody reads it as a cause.
    @ViewBuilder
    private var previousSessionSection: some View {
        if let recovery = centre.recovery, !recovery.endedCleanly {
            Section {
                Label(recovery.headline, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)

                if !recovery.enteredLocalInference {
                    // Section 97. The previous session ended badly, but it never
                    // reached Local AI — so this screen has nothing to say about
                    // it, and saying nothing is the correct answer.
                    Text(
                        "That session never used a local model, so nothing here explains it."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    if let completed = recovery.lastCompletedDescription {
                        LabeledContent("Last successful stage") {
                            Text(recovery.lastCompletedStage?.rawValue ?? "—")
                                .font(.footnote.monospaced())
                        }
                        .accessibilityLabel(completed)
                    }
                    if let deepest = recovery.deepestUnresolvedStage {
                        LabeledContent("Stopped during") {
                            Text(deepest.stage.rawValue)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Text(deepest.stage.displayName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("No matching EXIT was recorded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No unfinished stage was recorded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let modelID = recovery.modelID {
                        LabeledContent("Model", value: modelID)
                    }
                }

                Button("Dismiss This Notice") { centre.acknowledgeRecovery() }
                    .font(.footnote)
            } header: {
                Text("Previous Session")
            } footer: {
                // Sections 51 and 52: the thing this app genuinely cannot know.
                Text(LocalInferenceRecoverySummary.terminationReasonCaveat)
            }
        }
    }

    // MARK: Summary

    /// Section 54.
    private var summarySection: some View {
        Section("This Session") {
            LabeledContent("Session") {
                Text(centre.logger.appSessionID.shortDescription)
                    .font(.footnote.monospaced())
            }
            LabeledContent("Selected model", value: model.activeAssistantChoice?.title ?? "None")
            LabeledContent("Runtime", value: runtime?.implementation ?? "—")
            LabeledContent("App version", value: centre.header().appVersion)
            LabeledContent("Build", value: centre.header().buildNumber)
            LabeledContent("iOS", value: centre.header().osVersion)
            LabeledContent("Device", value: LocalInferenceDiagnosticsCentre.deviceModelIdentifier)
            LabeledContent(
                "Physical memory",
                value: LocalInferenceDiagnosticReport.byteLabel(
                    centre.header().physicalMemoryBytes
                )
            )
            if let failure = centre.logger.writerFailureDescription {
                // Section 83. The one thing that makes everything else on this
                // screen untrustworthy, so it is said plainly rather than hidden.
                Label(
                    "Diagnostic logging failed: \(failure)",
                    systemImage: "exclamationmark.octagon"
                )
                .foregroundStyle(.orange)
                .font(.footnote)
            }
        }
    }

    /// Sections 61 and 62, read from the last configuration the runtime wrote.
    @ViewBuilder
    private var configurationSection: some View {
        let configuration = latestConfiguration
        Section {
            if configuration.isEmpty {
                Text("No model has been loaded in this session yet.")
                    .foregroundStyle(.secondary)
            } else {
                row(configuration, .actualContextSize, "Context")
                row(configuration, .batchSize, "Batch")
                row(configuration, .microBatchSize, "Micro batch")
                row(configuration, .threadCount, "Threads")
                row(configuration, .compiledWithMetal, "Metal compiled")
                row(configuration, .requestedGPUOffload, "GPU offload requested")
                row(configuration, .runtimeGPUOffloadActive, "GPU offload active")
                row(configuration, .estimatedTotalBytes, "Estimated total", isBytes: true)
                row(configuration, .estimatedKVCacheBytes, "Estimated KV cache", isBytes: true)
            }
        } header: {
            Text("Runtime Configuration")
        } footer: {
            Text(
                "Memory figures are estimates from the app's own model, not "
                    + "measurements of free memory — iOS does not publish that to an app."
            )
        }
    }

    // MARK: The decode boundary

    /// Section 67. Everything that was true immediately before the last
    /// `llama_decode`, in one place.
    ///
    /// Collapsed by default and deliberately: it is twenty-odd numbers, and the
    /// person who needs them knows they need them. The one line outside the
    /// disclosure is whether that decode came back, which is the only part
    /// worth reading at a glance.
    @ViewBuilder
    private var decodeSnapshotSection: some View {
        let preflight = latestDecodePreflight
        Section {
            if preflight.isEmpty {
                Text("No prompt decode has been attempted in this session.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Outcome") {
                    Text(decodeOutcomeLabel)
                        .font(.footnote.monospaced())
                        .foregroundStyle(decodeOutcomeColour)
                }
                DisclosureGroup("Preflight Snapshot") {
                    ForEach(LocalInferenceDiagnosticReport.metadataLines(preflight), id: \.self) {
                        Text($0)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Last Prompt Decode Snapshot")
        } footer: {
            // Sections 50, 51 and 89 again, at the one place on this screen
            // where a reader is most tempted to conclude something.
            Text(
                "These are the values the batch and context actually held when the "
                    + "call was made. A snapshot with no outcome means the process did "
                    + "not come back from that call — which says where it stopped, not why."
            )
        }
    }

    /// Section 68. What llama.cpp itself said.
    @ViewBuilder
    private var nativeLogSection: some View {
        let lines = selectedSession.events.filter { $0.name == .nativeLog }
        Section {
            if lines.isEmpty {
                Text("The inference runtime has not reported anything in this session.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines.suffix(Self.nativeLogLimit), id: \.sequence) { event in
                    Text(
                        LocalInferenceDiagnosticReport.describe(
                            event.metadata[.errorReason] ?? .text("")
                        )
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colour(for: event))
                }
            }
        } header: {
            Text("llama.cpp Native Log")
        } footer: {
            Text(
                "Lines the inference engine printed itself, filtered to structural "
                    + "messages. Nothing derived from your messages is kept."
            )
        }
    }

    /// The last few, newest at the bottom. llama.cpp is talkative at load time
    /// and the whole run belongs in the export rather than on the screen.
    private static let nativeLogLimit = 25

    /// Sections 41, 42, 69, 70 and 71.
    @ViewBuilder
    private var minimalTestSection: some View {
        Section {
            if installedModels.isEmpty {
                Text("No local model is installed, so there is nothing to test.")
                    .foregroundStyle(.secondary)
            } else {
                // Section 71: named, not inferred. "Whichever model was
                // selected" is exactly the ambiguity that makes a test result
                // unusable a week later.
                Picker("Model", selection: $minimalTestModel) {
                    ForEach(installedModels) { status in
                        Text(status.descriptor.displayName)
                            .tag(Optional(status.id))
                    }
                }

                Button("Run Minimal Native Decode Test") { isConfirmingMinimalTest = true }
                    // Section 70: never alongside a live turn, and never twice
                    // at once.
                    .disabled(
                        isRunningMinimalTest
                            || model.isAssistantResponding
                            || minimalTestModel == nil
                    )

                if isRunningMinimalTest {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Running…").foregroundStyle(.secondary)
                    }
                }
                if let minimalOutcome {
                    Label(
                        minimalOutcome.summary,
                        systemImage: minimalOutcome.didSucceed
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(minimalOutcome.didSucceed ? Color.green : Color.orange)
                }
            }
        } header: {
            Text("Minimal Native Decode Test")
        } footer: {
            // Section 43: what each outcome does and does not license.
            Text(
                "Opens the chosen model on its own, with GPU offload off and a small "
                    + "context, and decodes one fixed word. If this succeeds while a real "
                    + "conversation does not, the difference is in what the full path does "
                    + "around the call. If it also fails, the problem is below this app. "
                    + "Neither outcome identifies a cause on its own."
            )
        }
    }

    private func runMinimalTest() {
        guard let modelID = minimalTestModel else { return }
        isRunningMinimalTest = true
        minimalOutcome = nil
        Task {
            let outcome = await model.runMinimalNativeDecodeTest(on: modelID)
            minimalOutcome = outcome
            isRunningMinimalTest = false
        }
    }

    // MARK: Advanced

    /// Section 69. Explicitly diagnostic, explicitly not a performance panel.
    private var advancedSection: some View {
        Section {
            Toggle(
                "Verbose Local AI Logging",
                isOn: Binding(get: { centre.isVerbose }, set: { centre.isVerbose = $0 })
            )

            Toggle(
                "Force CPU-Only Inference",
                isOn: overrideBinding(\.forceCPUOnly)
            )
            Toggle("Enable Metal / GPU", isOn: overrideBinding(\.gpuOffloadEnabled))
                // Section 71: two switches that can disagree about the same
                // hardware is a configuration nobody can reason about. CPU-only
                // wins, and the GPU switch goes out of reach rather than
                // silently losing.
                .disabled(centre.overrides.forceCPUOnly)
            Toggle("Use Conservative Context", isOn: overrideBinding(\.conservativeContext))
            Toggle("Use Conservative Batch", isOn: overrideBinding(\.conservativeBatch))

            Picker("Threads", selection: threadModeBinding) {
                ForEach(LocalInferenceThreadMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } header: {
            Text("Advanced Diagnostics")
        } footer: {
            // Section 77: these are context-creation parameters. Changing them
            // under a live `llama_context` would be ignored at best.
            Text(
                "These deliberately slow inference down to remove one variable at a time. "
                    + "They are not performance settings. A change takes effect the next time "
                    + "a model is loaded — unload the current model to apply it now.\n\n"
                    + "Critical crash breadcrumbs are always recorded, whatever the verbose "
                    + "setting."
            )
        }
    }

    // MARK: The log

    /// Sections 56 and 57.
    private var logSection: some View {
        Section {
            Picker("Session", selection: $selection) {
                Text("Current").tag(SessionChoice.current)
                Text("Previous").tag(SessionChoice.previous)
            }
            .pickerStyle(.segmented)
            .disabled(centre.recovery == nil)

            let session = selectedSession
            if session.events.isEmpty {
                Text("No events recorded.").foregroundStyle(.secondary)
            } else {
                // Newest last, which is the order the events happened and the
                // order the trail reads in. The interesting line is the final
                // one, so the view starts scrolled to it.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.events, id: \.sequence) { event in
                                Text(LocalInferenceDiagnosticReport.line(for: event))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(colour(for: event))
                                    .id(event.sequence)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onAppear {
                        proxy.scrollTo(session.events.last?.sequence, anchor: .bottom)
                    }
                }
            }
            if session.unreadableLineCount > 0 {
                Text(
                    "\(session.unreadableLineCount) line(s) could not be read — consistent "
                        + "with a write interrupted by termination."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Log")
        }
    }

    private var actionSection: some View {
        Section {
            Button(didCopy ? "Copied" : "Copy Log") {
                UIPasteboard.general.string = centre.report(for: selectedSessionID)
                didCopy = true
            }
            Button("Share Log") { shareURL = centre.exportFile(for: selectedSessionID) }
            Button("Export Diagnostic File") {
                shareURL = centre.exportFile(for: selectedSessionID)
            }
            Button("Clear Logs", role: .destructive) { isConfirmingClear = true }
        } footer: {
            // Section 128: nothing leaves the device unless a person sends it.
            Text(
                "Reports contain configuration, counts and timings only — never your "
                    + "messages, the assistant's replies, your memories or any credential. "
                    + "Nothing is uploaded anywhere; sharing is entirely up to you."
            )
        }
    }

    // MARK: Plumbing

    private var selectedSessionID: LocalInferenceSessionID {
        switch selection {
        case .current: return centre.logger.appSessionID
        case .previous: return centre.recovery?.sessionID ?? centre.logger.appSessionID
        }
    }

    private var selectedSession: LocalInferenceDecodedSession {
        centre.read(selectedSessionID)
    }

    /// The most recent decode preflight in whichever session is shown, falling
    /// back to the one the previous session left behind.
    ///
    /// The fallback is the interesting case: after a termination inside
    /// `llama_decode` the current session has no preflight at all, and the one
    /// worth reading belongs to the process that died.
    private var latestDecodePreflight: LocalInferenceMetadata {
        // `PROMPT_CHUNK` as well as `DECODE_PREFLIGHT`: a chunked prefill
        // writes one per chunk, and after a termination the last one written is
        // the chunk the process was on — which is the whole point of recording
        // them per chunk.
        selectedSession.events.last {
            $0.name == .decodePreflight || $0.name == .promptChunk
        }?.metadata
            ?? centre.recovery?.decodePreflight
            ?? .empty
    }

    /// Whether the last decode came back, and with what.
    private var decodeOutcomeLabel: String {
        guard let event = selectedSession.events.last(where: { $0.name == .decodeResult }) else {
            return "No result recorded"
        }
        guard let result = event.metadata[.validationResult] else { return "recorded" }
        return LocalInferenceDiagnosticReport.describe(result)
    }

    private var decodeOutcomeColour: Color {
        guard let event = selectedSession.events.last(where: { $0.name == .decodeResult }) else {
            return .orange
        }
        if case .text("success")? = event.metadata[.validationResult] { return .secondary }
        return .orange
    }

    /// The most recent runtime configuration line in whichever session is shown.
    private var latestConfiguration: LocalInferenceMetadata {
        selectedSession.events.last { $0.name == .runtimeConfiguration }?.metadata
            ?? centre.recovery?.configuration
            ?? .empty
    }

    @ViewBuilder
    private func row(
        _ metadata: LocalInferenceMetadata,
        _ key: LocalInferenceMetadataKey,
        _ label: String,
        isBytes: Bool = false
    ) -> some View {
        if let value = metadata[key] {
            LabeledContent(label) {
                Text(display(value, isBytes: isBytes))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func display(_ value: LocalInferenceMetadataValue, isBytes: Bool) -> String {
        if isBytes {
            switch value {
            case .int(let number):
                return LocalInferenceDiagnosticReport.byteLabel(Int64(number))
            case .int64(let number):
                return LocalInferenceDiagnosticReport.byteLabel(number)
            default: break
            }
        }
        if case .bool(let flag) = value { return flag ? "Yes" : "No" }
        return LocalInferenceDiagnosticReport.describe(value)
    }

    private func colour(for event: LocalInferenceDiagnosticEvent) -> Color {
        switch event.level {
        case .error: return .orange
        case .warning: return .yellow
        case .info, .debug:
            // ENTER is the line that matters when the trail stops, so it reads
            // differently from everything around it.
            return event.type == .enter ? .primary : .secondary
        }
    }

    private func overrideBinding(
        _ path: WritableKeyPath<LocalInferenceDiagnosticOverrides, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { centre.overrides[keyPath: path] },
            set: { newValue in
                var updated = centre.overrides
                updated[keyPath: path] = newValue
                centre.overrides = updated
                apply(updated)
            }
        )
    }

    private var threadModeBinding: Binding<LocalInferenceThreadMode> {
        Binding(
            get: { centre.overrides.threadMode },
            set: { newValue in
                var updated = centre.overrides
                updated.threadMode = newValue
                centre.overrides = updated
                apply(updated)
            }
        )
    }

    /// Hands the new overrides to the manager, for the next load.
    private func apply(_ overrides: LocalInferenceDiagnosticOverrides) {
        Task { await model.localModels.setDiagnosticOverrides(overrides) }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        LocalInferenceDiagnosticsView()
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
