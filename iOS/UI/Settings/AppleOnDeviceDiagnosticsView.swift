import AIProviderApple
import SwiftUI
import UIKit

/// Whether the on-device model is usable yet, and what Apple actually reports.
///
/// ## The question this screen answers
///
/// Two questions, in the order a person asks them. First: *can I use it, and if
/// not, is that going to change?* Second, only if something looks wrong: *what
/// exactly did Apple say?*
///
/// So the status comes first, in plain words, and the diagnostic rows from the
/// previous debug pass follow underneath. Improving the first was not a reason
/// to remove the second — a tester who can read "modelPreparing" off the screen
/// can put it in a message, and that is worth keeping.
///
/// ## What is deliberately absent
///
/// A progress bar, a percentage, a byte count, a rate, an estimate. Apple
/// exposes availability and nothing else, and every one of those would be
/// invented. An invented bar that stalls is worse than no bar: it makes a
/// person conclude the app is broken when iOS is simply still working.
///
/// An indeterminate spinner is the honest shape — something is happening, and
/// nobody can say how much of it is left.
///
/// ## Ownership
///
/// The polling lives in `AppleModelStatusCoordinator`, not in this body, and
/// the framework query lives in `AppleFoundationModelsProvider`, not in the
/// coordinator. This file does not import FoundationModels.
struct AppleOnDeviceDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// Created once per appearance of this screen, and stopped when it goes.
    @State private var status: AppleModelStatusCoordinator?
    @State private var didCopy = false

    var body: some View {
        List {
            if let status {
                statusSection(status)
                if let snapshot = status.diagnostic {
                    frameworkSection(snapshot)
                    systemSection(snapshot)
                    copySection(snapshot)
                }
            } else {
                Section {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading the on-device model state…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Apple On-Device")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // One coordinator per appearance. `.task` can run again if the view
            // is rebuilt, so the existing one is reused rather than replaced —
            // two would mean two loops.
            let coordinator = status ?? model.makeAppleModelStatusCoordinator()
            status = coordinator
            await coordinator.begin()
        }
        .onDisappear {
            // The single most important line here. Without it, walking away
            // from a preparing model leaves a timer running for the rest of the
            // session.
            status?.end()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding suspends the loop rather than leaving it to fire on
            // return; coming back does one immediate read, which is what
            // somebody who just switched Apple Intelligence on expects to see.
            guard let status else { return }
            switch phase {
            case .active:
                Task {
                    await status.refresh()
                    status.startAutomaticRefreshIfNeeded()
                }
            case .background:
                status.end()
            default:
                break
            }
        }
    }

    // MARK: Status

    private func statusSection(_ coordinator: AppleModelStatusCoordinator) -> some View {
        Section {
            LabeledContent("Status") {
                Text(coordinator.status.title)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(tint(for: coordinator.status))
            }

            Text(coordinator.status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Indeterminate, always. There is no number to put here.
            if coordinator.status.showsActivityIndicator {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Last checked") {
                Text(lastCheckedText(coordinator))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await coordinator.refresh() }
            } label: {
                HStack {
                    Text("Check Again")
                    Spacer()
                    if coordinator.isChecking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(coordinator.isChecking)
        } header: {
            Text("Apple On-Device")
        } footer: {
            if coordinator.isAutomaticallyRefreshing {
                Text(
                    "Checking again every \(Int(AppleModelStatusCoordinator.automaticRefreshInterval)) "
                        + "seconds while this screen is open. It will switch to Ready on its own."
                )
            } else {
                Text("iOS decides when the model is ready. MetisAI only reads what it reports.")
            }
        }
    }

    /// The timestamp of the last completed check, in the reader's own locale.
    ///
    /// Time only, not the date: this screen is watched while something is
    /// happening, and a date would be noise on every line.
    private func lastCheckedText(_ coordinator: AppleModelStatusCoordinator) -> String {
        guard let date = coordinator.lastCheckedAt else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func tint(for status: AppleModelStatus) -> Color {
        switch status {
        case .ready: return .green
        case .modelPreparing, .appleIntelligenceDisabled: return .orange
        case .deviceNotEligible, .unknownUnavailable: return .secondary
        case .checkFailed: return .red
        }
    }

    // MARK: The framework path

    /// Kept from the previous debug pass.
    ///
    /// If `Framework compiled` is No in a TestFlight build, nothing above it
    /// matters — the code that talks to the model was compiled out.
    private func frameworkSection(_ snapshot: AppleFoundationModelsDiagnostic) -> some View {
        Section {
            DiagnosticRow("Framework compiled", yesNo(snapshot.frameworkCompiled))
            DiagnosticRow("Runtime API supported", yesNo(snapshot.runtimeSupported))
            DiagnosticRow("Provider path active", snapshot.providerImplementation)
            DiagnosticRow(
                "System model available",
                snapshot.systemModelIsAvailable.map(yesNo) ?? "Not read"
            )
            DiagnosticRow("Raw availability", snapshot.rawAvailability)
            DiagnosticRow("Reason token", snapshot.reasonToken)
            DiagnosticRow("Mapped state", snapshot.mappedAvailabilityToken)
        } header: {
            Text("Framework Path")
        } footer: {
            Text(
                "\"Framework compiled\" is whether this build of MetisAI contains the "
                    + "Foundation Models integration at all. \"Runtime API supported\" is "
                    + "whether this version of iOS provides it."
            )
        }
    }

    private func systemSection(_ snapshot: AppleFoundationModelsDiagnostic) -> some View {
        Section {
            DiagnosticRow(snapshot.osName, snapshot.osVersion)
            DiagnosticRow("Locale", snapshot.currentLocaleIdentifier)
            if let supported = snapshot.currentLocaleSupported {
                DiagnosticRow("Current locale supported", yesNo(supported))
            }
            if let count = snapshot.supportedLanguageCount {
                DiagnosticRow("Supported languages", "\(count)")
            }
        } header: {
            Text("System")
        } footer: {
            Text("An unsupported language is not the same thing as an ineligible device.")
        }
    }

    private func copySection(_ snapshot: AppleFoundationModelsDiagnostic) -> some View {
        Section {
            Button {
                UIPasteboard.general.string = snapshot.report
                didCopy = true
            } label: {
                Text(didCopy ? "Copied" : "Copy Diagnostics")
            }
        } footer: {
            Text("Nothing on this screen is stored. Every value is read when it is shown.")
        }
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
}

/// One label and one monospaced value.
///
/// Monospaced deliberately: these are values to be compared and transcribed,
/// not read as prose.
private struct DiagnosticRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
