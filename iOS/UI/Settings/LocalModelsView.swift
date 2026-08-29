import AIProviderLocal
import AIProviderLocalLlama
import AssistantDomain
import NativeModelKit
import SwiftUI
import UIKit

/// Manage Models: what can be downloaded, what is here, and what is in use.
///
/// Three things this screen has to get right:
///
/// 1. **It refuses before it costs anything.** A model that will not fit shows
///    why and has no Download button — spending someone's data allowance to
///    tell them something knowable beforehand is the failure sections 8 and 12
///    exist to prevent.
/// 2. **Ready means ready.** A row says Ready only after the file has been
///    checksummed, structurally validated and installed (section 73). While
///    that is happening it says Verifying.
/// 3. **It speaks English.** No GGUF, no quantization theory, no context
///    windows (section 70). "1.7B · Q4_K_M" survives as a caption because it is
///    what people compare downloads by; nothing requires understanding it.
struct LocalModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = LocalModelsViewModel()
    @State private var runtime: LocalRuntimeDiagnostic?
    @State private var didCopyRuntime = false

    var body: some View {
        List {
            filterSection

            if let failure = viewModel.failure {
                Section {
                    FailureRow(failure: failure) {
                        guard let status = viewModel.status(for: failure.modelID) else { return }
                        // Retry means the thing that failed, not "download".
                        // Re-fetching two gigabytes because a load ran out of
                        // memory would be the wrong repair, and an expensive one.
                        Task {
                            switch failure.kind {
                            case .download:
                                await viewModel.download(status, manager: model.localModels)
                            case .load:
                                await viewModel.load(status, manager: model.localModels)
                            case .delete:
                                await viewModel.delete(status, manager: model.localModels)
                            }
                        }
                    }
                }
            }

            runtimeSection

            Section {
                if viewModel.visibleStatuses.isEmpty {
                    Text(
                        viewModel.isFiltering
                            ? "No models match this search."
                            : "No models are available."
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(viewModel.visibleStatuses) { status in
                    LocalModelRow(
                        status: status,
                        rowState: viewModel.rowState(for: status),
                        viewModel: viewModel,
                        isDownloading: viewModel.isDownloading(status.id),
                        isWorking: viewModel.isWorking == status.id,
                        progress: viewModel.progress,
                        onAction: { action in
                            Task {
                                await viewModel.perform(
                                    action, on: status, manager: model.localModels
                                )
                            }
                        }
                    )
                }
            } header: {
                HStack {
                    Text("Models")
                    Spacer()
                    if viewModel.isFiltering {
                        Text("\(viewModel.visibleStatuses.count) of \(viewModel.statuses.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(LocalModelPresentation.privacySummary)
            }

            Section {
                LabeledContent("Used by models", value: LocalModelPresentation.size(viewModel.storageUsed))
                LabeledContent("Free on this device", value: LocalModelPresentation.size(viewModel.storageAvailable))
            } header: {
                Text("Storage")
            } footer: {
                Text(LocalModelPresentation.batteryNote)
            }
        }
        .navigationTitle("Manage Models")
        .navigationBarTitleDisplayMode(.inline)
        // Searchable rather than a text field in a row: it gets the system
        // keyboard dismissal, the clear button and the scroll-to-reveal
        // behaviour people already expect, none of which is worth rebuilding.
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search models"
        )
        .task { await viewModel.refresh(model.localModels) }
        // Refreshed on every appearance rather than once: free space and the
        // loaded model both change while this screen is off screen.
        .refreshable { await viewModel.refresh(model.localModels) }
        .task { runtime = await model.localRuntimeDiagnostic() }
        // Delete is confirmed here as well as on the detail screen, because it
        // is now reachable from a row — and a destructive tap in a scrolling
        // list is exactly where a confirmation earns its place.
        .confirmationDialog(
            viewModel.pendingDeletion.map { "Delete \($0.descriptor.displayName)?" } ?? "",
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let pending = viewModel.pendingDeletion else { return }
                Task { await viewModel.delete(pending, manager: model.localModels) }
            }
            Button("Cancel", role: .cancel) { viewModel.pendingDeletion = nil }
        } message: {
            if let pending = viewModel.pendingDeletion {
                Text(LocalModelPresentation.deletionExplanation(pending))
            }
        }
    }

    // MARK: The runtime

    /// Whether this build can run a local model at all.
    ///
    /// First, because it is the precondition for everything below it. A phone
    /// with four downloaded models and no inference engine can do nothing with
    /// any of them, and until this row existed the only clue was a compatibility
    /// warning on each model that read as though the *models* were the problem.
    @ViewBuilder
    private var runtimeSection: some View {
        if let runtime {
            Section {
                LabeledContent("Status") {
                    Text(runtime.title)
                        .foregroundStyle(runtime.isReadyToRun ? Color.green : Color.orange)
                }
                LabeledContent("Runtime") {
                    Text(runtime.implementation + (runtime.pinnedVersion.map { " \($0)" } ?? ""))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Platform") {
                    Text(runtime.platform)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("GPU (Metal)") {
                    Text(runtime.usesMetal ? "Enabled" : "Disabled")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button(didCopyRuntime ? "Copied" : "Copy Runtime Diagnostics") {
                    UIPasteboard.general.string = runtime.report(
                        installedModels: viewModel.installedCount,
                        runnableModels: viewModel.runnableCount
                    )
                    didCopyRuntime = true
                }
            } header: {
                Text("On-Device Inference Runtime")
            } footer: {
                Text(runtime.detail)
            }
        }
    }

    // MARK: Filtering

    private var filterSection: some View {
        Section {
            Picker("Show", selection: $viewModel.filter) {
                ForEach(LocalModelFilter.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

/// One model in the list.
private struct LocalModelRow: View {
    let status: LocalModelStatus
    /// What this row says and offers, derived in the package.
    let rowState: LocalModelRowState
    // The detail screen is pushed with a destination rather than a routed
    // value: `SettingsScreen` already registers a `navigationDestination` for
    // `Route`, and a second registration for the same type in one stack is
    // undefined behaviour that SwiftUI warns about. It also lets the detail
    // share this screen's view model instead of re-querying the manager.
    let viewModel: LocalModelsViewModel
    let isDownloading: Bool
    /// A load or unload is running for this model.
    let isWorking: Bool
    let progress: LocalModelDownloadProgress
    let onAction: (LocalModelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                NavigationLink {
                    LocalModelDetailView(status: status, viewModel: viewModel)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(status.descriptor.displayName)
                                .font(.headline)
                            if status.isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("In use")
                            }
                        }
                        // Size, precision and family on one line (section 42).
                        // Every part is omitted when unknown rather than
                        // guessed at — section 41.
                        Text(specification)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                CompatibilityBadge(status: status)
                RuntimeStateLabel(state: rowState.runtime)
                if isWorking {
                    ProgressView().controlSize(.mini)
                }
            }

            if let summary = status.descriptor.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = rowState.runtime.detail
                ?? LocalModelPresentation.compatibilityDetail(status)
            {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        rowState.runtime.isError
                            || LocalModelPresentation.isWarning(status.compatibility)
                            ? .orange : .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDownloading {
                DownloadProgressView(progress: progress) { onAction(.cancelDownload) }
            } else {
                actions
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// "1.2 GB · Q4_K_M · qwen3", with whatever parts are known.
    private var specification: String {
        [rowState.sizeLabel, rowState.precisionLabel, rowState.familyLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(rowState.actions) { action in
                Button(
                    action.title,
                    role: action.isDestructive ? .destructive : nil
                ) {
                    onAction(action)
                }
                // Bordered rather than plain: a row in a `List` is itself a tap
                // target, and an unadorned button on one gets absorbed by it.
                .buttonStyle(.bordered)
                .tint(action.isProminent ? Color.accentColor : .secondary)
                .controlSize(.small)
                .disabled(isWorking)
            }
            if rowState.runtime.isBusy && !isDownloading {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The runtime half of a row's state, as a small caption.
private struct RuntimeStateLabel: View {
    let state: LocalModelRuntimeState

    var body: some View {
        Text(state.label)
            .font(.caption2)
            .foregroundStyle(state.isError ? Color.orange : .secondary)
            .accessibilityLabel("Runtime state, \(state.label)")
    }
}

/// The fit badge. Never a speed claim.
private struct CompatibilityBadge: View {
    let status: LocalModelStatus

    var body: some View {
        Text(LocalModelPresentation.compatibilityLabel(status))
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var tint: Color {
        switch status.compatibility {
        case .compatible: return .green
        case .compatibleWithWarning, .unknown: return .orange
        case .likelyTooLarge, .insufficientStorage, .unsupportedFormat,
             .unsupportedArchitecture, .unsupportedOS:
            return .secondary
        }
    }
}

/// Bytes, a percentage and a way out (sections 19 and 20).
private struct DownloadProgressView: View {
    let progress: LocalModelDownloadProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let fraction = progress.fractionComplete {
                ProgressView(value: fraction)
            } else {
                // No content length from the server. An indeterminate bar is
                // honest; a bar stuck at zero looks broken.
                ProgressView()
            }
            HStack {
                Text(LocalModelPresentation.transferred(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !progress.percentLabel.isEmpty {
                    Text(progress.percentLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading, \(progress.percentLabel)")
    }
}

/// What went wrong, and whether trying again is worth it.
private struct FailureRow: View {
    let failure: LocalModelsViewModel.Failure
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                Text(failure.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if failure.isRetryable {
                Button("Try Again", action: onRetry)
                    .font(.subheadline)
            }
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        LocalModelsView()
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
