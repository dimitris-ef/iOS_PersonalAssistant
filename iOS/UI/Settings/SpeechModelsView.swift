import SpeechToText
import SpeechToTextLocal
import SwiftUI

/// Managing on-device speech models: download, switch, delete.
///
/// Deliberately a sibling of `LocalModelsView` rather than a section inside it.
/// Section 27 and 37: these are different models for a different purpose, and
/// putting Whisper Base next to Qwen in one list would make "which of these is
/// my assistant?" a question the user has to work out.
struct SpeechModelsView: View {
    @Environment(AppModel.self) private var model

    @State private var statuses: [LocalSpeechModelManager.Status] = []
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Section {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(statuses) { status in
                    SpeechModelRow(
                        status: status,
                        onDownload: { await download(status) },
                        onCancel: { await cancel(status) },
                        onSelect: { await select(status) },
                        onDelete: { await delete(status) }
                    )
                }
            } header: {
                Text("Speech Models")
            } footer: {
                Text(
                    "Downloaded models transcribe on this iPhone with no internet "
                        + "connection. Deleting one does not affect your assistant "
                        + "model, tasks, or memories."
                )
            }
        }
        .navigationTitle("Speech Models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        statuses = await model.speechModelStatuses()
    }

    private func download(_ status: LocalSpeechModelManager.Status) async {
        failure = nil
        do {
            try await model.downloadSpeechModel(status.id)
        } catch let error as SpeechToTextError {
            failure = error.message
        } catch {
            failure = "The speech model could not be downloaded."
        }
        await refresh()
    }

    private func cancel(_ status: LocalSpeechModelManager.Status) async {
        await model.cancelSpeechModelDownload(status.id)
        await refresh()
    }

    private func select(_ status: LocalSpeechModelManager.Status) async {
        await model.selectSpeechModel(status.id)
        await refresh()
    }

    private func delete(_ status: LocalSpeechModelManager.Status) async {
        failure = nil
        do {
            try await model.deleteSpeechModel(status.id)
        } catch let error as SpeechToTextError {
            failure = error.message
        } catch {
            failure = "The speech model could not be removed."
        }
        await refresh()
    }
}

/// One model: what it is, what it costs, and the one action that makes sense.
private struct SpeechModelRow: View {
    let status: LocalSpeechModelManager.Status
    let onDownload: () async -> Void
    let onCancel: () async -> Void
    let onSelect: () async -> Void
    let onDelete: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.descriptor.displayName)
                    Text(status.descriptor.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if status.isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }

            HStack(spacing: 8) {
                Text(SpeechModelByteFormat.string(status.descriptor.fileSize))
                Text("·")
                Text(status.descriptor.quantization.displayName)
                if status.descriptor.isEnglishOnly {
                    Text("·")
                    Text("English")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Section 30: one lifecycle value, so the row cannot say two
            // contradictory things at once.
            statusLine

            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status.lifecycle {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                // Section 31: bytes and a percentage, not a bare spinner.
                ProgressView(value: progress.fractionComplete ?? 0)
                Text(progress.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .verifying, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(status.lifecycle.label).font(.caption)
            }
        case .failed(let reason), .incompatible(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
        case .ready, .downloaded:
            Text(status.lifecycle.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notDownloaded:
            if let reason = status.compatibility.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(status.compatibility.permitsDownload ? .secondary : .orange)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 16) {
            if case .downloading = status.lifecycle {
                Button("Cancel", role: .cancel) { Task { await onCancel() } }
            } else if status.canDownload {
                Button("Download") { Task { await onDownload() } }
            } else if status.lifecycle.isInstalled {
                if !status.isSelected {
                    Button("Use This") { Task { await onSelect() } }
                }
                Button("Delete", role: .destructive) { Task { await onDelete() } }
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
    }
}
