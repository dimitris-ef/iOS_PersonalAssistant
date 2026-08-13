import AssistantDomain
import SwiftUI

/// A calendar event and the support the assistant built around it.
///
/// The reminder plan gets as much room as the event itself, because for this
/// product the plan is the interesting half: anyone can store "Haircut, 10 PM".
struct EventDetailView: View {
    let eventID: CalendarItem.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingCancel = false

    private var event: CalendarItem? { model.event(id: eventID) }

    var body: some View {
        Group {
            if let event {
                content(for: event)
            } else {
                EmptyStateView(
                    systemImage: "calendar.badge.exclamationmark",
                    title: "Event not found",
                    message: "It may have been removed."
                )
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(for event: CalendarItem) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(event.title)
                        .font(.title2.weight(.semibold))
                    Text(AppFormatters.shared.fullDate(event.start))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(AppFormatters.shared.timeRange(from: event.start, to: event.end))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityElement(children: .combine)
            }

            Section {
                if let location = event.location {
                    LabeledContent("Location", value: location)
                }
                if let travel = event.travelDuration {
                    LabeledContent(
                        "Travel",
                        value: AppFormatters.shared.minutesLabel(travel)
                    )
                }
                if let preparation = event.preparationDuration {
                    LabeledContent(
                        "Getting ready",
                        value: AppFormatters.shared.minutesLabel(preparation)
                    )
                }
                LabeledContent(
                    "Priority",
                    value: ImportanceStyle.label(for: event.importance)
                )
            }

            if let plan = model.reminderPlan(forEvent: event.id) {
                reminderSection(plan: plan)
            }

            Section {
                Button {
                    model.banner = BannerMessage(
                        text: "Editing events arrives with the calendar integration.",
                        style: .neutral
                    )
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    isConfirmingCancel = true
                } label: {
                    Label("Cancel event", systemImage: "calendar.badge.minus")
                }
            } footer: {
                // Said outright: this event lives in a mock service, not in the
                // user's real calendar.
                Text("This event is held by the app's mock calendar. Nothing has been written to your device calendar yet.")
            }
        }
        .confirmationDialog(
            "Cancel this event?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel event", role: .destructive) {
                model.banner = BannerMessage(
                    text: "Cancelling events arrives with the calendar integration.",
                    style: .neutral
                )
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func reminderSection(plan: ReminderPlan) -> some View {
        let presentation = ReminderPlanPresentation.make(
            from: plan,
            now: model.now,
            calendar: model.calendar
        )

        Section {
            ReminderTimelineView(plan: presentation) { stage in
                simulate(stage: stage, plan: plan)
            }
            .padding(.vertical, Theme.Spacing.sm)
        } header: {
            Text("Reminder plan")
        } footer: {
            Text(
                presentation.requiresExplicitConfirmation
                    ? "Dismissing one of these won't mark anything done — I'll keep checking until you confirm."
                    : "Tap a stage to preview how the reminder will look."
            )
        }
    }

    private func simulate(stage: ReminderPlanPresentation.Stage, plan: ReminderPlan) {
        guard let domainStage = plan.stages.first(where: { $0.id == stage.id }) else { return }
        model.simulateReminder(
            for: SimulatedReminder.from(
                stage: domainStage,
                plan: plan,
                anchor: plan.subject.anchor.date ?? stage.fireDate,
                formatter: AppFormatters.shared
            )
        )
        dismiss()
    }
}

/// A reminder plan on its own, opened from a conversation card.
struct ReminderPlanDetailView: View {
    let planID: ReminderPlan.ID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let plan = model.reminderPlan(id: planID) {
                let presentation = ReminderPlanPresentation.make(
                    from: plan,
                    now: model.now,
                    calendar: model.calendar
                )

                List {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(presentation.subjectTitle)
                                .font(.title2.weight(.semibold))
                            Text(presentation.anchorLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }

                    Section {
                        ReminderTimelineView(plan: presentation)
                            .padding(.vertical, Theme.Spacing.sm)
                    } header: {
                        Text("How I'll help")
                    } footer: {
                        if let followUp = presentation.followUpSummary {
                            Text(followUp)
                        }
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "bell.slash",
                    title: "Plan not found",
                    message: "This reminder plan is no longer available."
                )
            }
        }
        .navigationTitle("Reminder plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        EventDetailView(eventID: .init())
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
