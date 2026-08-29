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
                        Task { await viewModel.download(status, manager: model.localModels) }
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
                        viewModel: viewModel,
                        isDownloading: viewModel.isDownloading(status.id),
                        progress: viewModel.progress,
                        onDownload: {
                            Task { await viewModel.download(status, manager: model.localModels) }
                        },
                        onCancel: {
                            Task { await viewModel.cancelDownload(model.localModels) }
                        },
                        onUse: {
                            Task { await viewModel.use(status, manager: model.localModels) }
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
    // The detail screen is pushed with a destination rather than a routed
    // value: `SettingsScreen` already registers a `navigationDestination` for
    // `Route`, and a second registration for the same type in one stack is
    // undefined behaviour that SwiftUI warns about. It also lets the detail
    // share this screen's view model instead of re-querying the manager.
    let viewModel: LocalModelsViewModel
    let isDownloading: Bool
    let progress: LocalModelDownloadProgress
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onUse: () -> Void

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
                        Text(LocalModelPresentation.specification(status.descriptor))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(LocalModelPresentation.size(status.descriptor.fileSizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            CompatibilityBadge(status: status)

            if let summary = status.descriptor.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = LocalModelPresentation.compatibilityDetail(status) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        LocalModelPresentation.isWarning(status.compatibility) ? .orange : .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDownloading {
                DownloadProgressView(progress: progress, onCancel: onCancel)
            } else {
                actions
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            if status.lifecycle.isInstalled {
                if !status.isSelected {
                    Button("Use Model", action: onUse)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if !status.lifecycle.isLoaded {
                    // Selected but not resident: loading is what turns this into
                    // Ready, and it happens on demand rather than at launch.
                    Button("Load", action: onUse)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text(LocalModelPresentation.statusLabel(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status.canDownload {
                Button("Download", action: onDownload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if status.lifecycle.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
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
