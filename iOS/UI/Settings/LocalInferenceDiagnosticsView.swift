import AIProviderLocal
import AIProviderLocalLlama
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
            advancedSection
            logSection
            actionSection
        }
        .navigationTitle("Local AI Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { runtime = await model.localRuntimeDiagnostic() }
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
