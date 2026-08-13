import AssistantDomain
import SwiftUI

/// An in-app preview of a reminder, with the responses a real notification
/// will eventually offer.
///
/// **This is a simulation.** Nothing was scheduled with iOS, and this sheet
/// only appears while the app is open. It exists so the response flow — and
/// specifically the difference between dismissing and confirming — can be
/// designed and exercised now.
///
/// TODO-XCODE: the real version is a `UNNotificationCategory` with matching
/// actions, handled by a `UNUserNotificationCenterDelegate` that feeds the same
/// `EngagementEvent`s into the core.
struct SimulatedReminderView: View {
    let reminder: SimulatedReminder

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            simulationNotice

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: ReminderStageStyle.symbol(for: reminder.stageKind))
                        .font(.footnote)
                        .foregroundStyle(ReminderStageStyle.tint(for: reminder.stageKind))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(
                                ReminderStageStyle.tint(for: reminder.stageKind).opacity(0.14)
                            )
                        )

                    Text(escalationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(reminder.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(reminder.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            actions

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xl)
    }

    private var simulationNotice: some View {
        Label("Simulated reminder — nothing was scheduled on this device", systemImage: "testtube.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                respond(.doingIt)
            } label: {
                Label("I'm doing it", systemImage: "figure.walk")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if reminder.requiresConfirmation {
                Button {
                    respond(.completed)
                } label: {
                    Label("It's done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    respond(.snooze)
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    respond(.dismiss)
                } label: {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            if reminder.requiresConfirmation {
                // Stated up front, so the behaviour is never a surprise.
                Text("Dismissing won't mark this done — I'll come back to it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private var escalationLabel: String {
        switch reminder.escalation {
        case .gentle: return "Quiet reminder"
        case .standard: return "Reminder"
        case .insistent: return "Time-sensitive"
        case .alarm: return "Alarm"
        }
    }

    private func respond(_ response: SimulatedReminderResponse) {
        Task { await model.respondToSimulatedReminder(response) }
        dismiss()
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    SimulatedReminderView(
        reminder: SimulatedReminder(
            title: "Time to start getting ready",
            body: "Work starts at 4:00 PM.",
            subject: .event(.init()),
            stageKind: .preparation,
            escalation: .standard,
            requiresConfirmation: true
        )
    )
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
