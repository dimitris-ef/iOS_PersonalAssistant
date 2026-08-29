import AIProviderApple
import SwiftUI
import UIKit

/// What Apple actually reports about the on-device model, on this device, now.
///
/// ## Why this screen exists
///
/// "Apple On-Device — Unavailable" is the same six words for six unrelated
/// situations: the model is still downloading, Apple Intelligence is switched
/// off, the hardware is ineligible, the OS predates the framework, the *build*
/// has no framework in it, or Apple returned a reason released after this app
/// was compiled. One of those resolves itself in minutes and one of them never
/// will, and until this screen existed there was no way to tell them apart from
/// the phone in your hand.
///
/// So it shows both halves: a sentence for the person reading it, and the exact
/// token Apple's API returned, which is the thing worth putting in a bug report.
///
/// ## What it is not
///
/// Not a second source of truth. Every value comes through `AppModel` →
/// `AppEnvironment` → `AppleFoundationModelsProvider` → its availability
/// reader — the same path `respond(to:)` uses to decide whether it can answer.
/// This file does not import FoundationModels and could not read the framework
/// if it wanted to.
struct AppleOnDeviceDiagnosticsView: View {
    @Environment(AppModel.self) private var model

    @State private var snapshot: AppleFoundationModelsDiagnostic?
    @State private var isRefreshing = false
    @State private var didCopy = false

    var body: some View {
        List {
            if let snapshot {
                statusSection(snapshot)
                frameworkSection(snapshot)
                systemSection(snapshot)
                actionsSection(snapshot)
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
        .task { await refresh() }
    }

    // MARK: Status

    private func statusSection(_ snapshot: AppleFoundationModelsDiagnostic) -> some View {
        Section {
            LabeledContent("Status") {
                Text(snapshot.state == .ready ? "Available" : "Unavailable")
                    .foregroundStyle(snapshot.state == .ready ? Color.green : Color.orange)
            }
            // Section 6 and 7: the token, verbatim, not a friendly paraphrase.
            // This is the value that makes a bug report actionable.
            LabeledContent("Reason") {
                Text(snapshot.reasonToken)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Foundation Models")
        } footer: {
            Text(snapshot.headline)
        }
    }

    // MARK: The framework path

    /// The section that answers "is the integration even in this build".
    ///
    /// If `Framework compiled` is No in a TestFlight build, nothing else on
    /// this screen matters and no amount of Apple Intelligence on the device
    /// will help — the code that talks to the model was compiled out.
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
            // Section 19: kept explicitly separate from eligibility.
            Text(
                "An unsupported language is not the same thing as an ineligible device."
            )
        }
    }

    // MARK: Actions

    private func actionsSection(_ snapshot: AppleFoundationModelsDiagnostic) -> some View {
        Section {
            Button {
                Task { await refresh() }
            } label: {
                HStack {
                    Text("Refresh Status")
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRefreshing)

            Button {
                UIPasteboard.general.string = snapshot.report
                didCopy = true
            } label: {
                Text(didCopy ? "Copied" : "Copy Diagnostics")
            }
        } footer: {
            Text(
                "Nothing here is stored. Refreshing asks the system again, so a model "
                    + "that was still downloading can become available without "
                    + "reinstalling the app."
            )
        }
    }

    private func refresh() async {
        isRefreshing = true
        didCopy = false
        snapshot = await model.appleFoundationModelsDiagnostic()
        // The selector's own status pill is read from the same provider, so it
        // is refreshed together — otherwise this screen could say "available"
        // while the list behind it still said otherwise.
        await model.refreshProviderState()
        isRefreshing = false
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
