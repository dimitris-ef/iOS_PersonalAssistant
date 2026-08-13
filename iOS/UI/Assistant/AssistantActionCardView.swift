import AssistantDomain
import SwiftUI

/// A structured result shown beneath an assistant reply.
///
/// Every case shares the same chrome — icon, title, supporting line, honesty
/// badge — so a new capability becomes one small view rather than a new visual
/// language. Adding routines or automations later means adding a case to
/// `AssistantActionPresentation` and a body here.
struct AssistantActionCardView: View {
    let action: AssistantActionPresentation
    @State private var route: DetailRoute?

    var body: some View {
        Group {
            switch action {
            case .calendarEvent(let model):
                eventCard(model)
            case .task(let model):
                taskCard(model)
            case .alarm(let model):
                alarmCard(model)
            case .memory(let model):
                memoryCard(model)
            case .reminderPlan(let plan):
                planCard(plan)
            case .unsupported(let model):
                genericCard(model)
            }
        }
        .detailSheet(route: $route)
    }

    // MARK: Cases

    private func eventCard(_ model: EventActionModel) -> some View {
        ActionCardChrome(
            symbol: "calendar",
            tint: .accentColor,
            title: model.title,
            subtitle: model.whenLabel,
            detail: model.location,
            fidelity: model.fidelity,
            onOpen: model.eventID.map { id in { route = .event(id) } }
        ) {
            if let plan = model.reminderPlan, !plan.isEmpty {
                ActionCardPlanSection(plan: plan)
            }
        }
    }

    private func taskCard(_ model: TaskActionModel) -> some View {
        ActionCardChrome(
            symbol: "checklist",
            tint: .accentColor,
            title: model.title,
            subtitle: model.timingLabel,
            detail: nil,
            fidelity: model.fidelity,
            onOpen: model.taskID.map { id in { route = .task(id) } }
        ) {
            if let plan = model.reminderPlan, !plan.isEmpty {
                ActionCardPlanSection(plan: plan)
            }
        }
    }

    private func alarmCard(_ model: AlarmActionModel) -> some View {
        ActionCardChrome(
            symbol: "alarm",
            tint: .red,
            title: model.label,
            subtitle: model.whenLabel,
            detail: model.allowsSnooze ? "Snooze allowed" : "No snooze",
            fidelity: model.fidelity,
            onOpen: nil
        ) { EmptyView() }
    }

    private func memoryCard(_ model: MemoryActionModel) -> some View {
        ActionCardChrome(
            symbol: MemoryPresenter().symbol(for: model.kind),
            tint: .purple,
            title: "Remembered",
            subtitle: model.content,
            detail: MemoryPresenter().kindLabel(for: model.kind),
            fidelity: model.fidelity,
            onOpen: nil
        ) { EmptyView() }
    }

    private func planCard(_ plan: ReminderPlanPresentation) -> some View {
        ActionCardChrome(
            symbol: "bell.badge",
            tint: .orange,
            title: plan.subjectTitle,
            subtitle: plan.anchorLabel,
            detail: nil,
            fidelity: .applied,
            onOpen: { route = .reminderPlan(plan.id) }
        ) {
            ActionCardPlanSection(plan: plan)
        }
    }

    private func genericCard(_ model: GenericActionModel) -> some View {
        ActionCardChrome(
            symbol: "sparkles",
            tint: .secondary,
            title: model.title,
            subtitle: model.detail,
            detail: nil,
            fidelity: model.fidelity,
            onOpen: nil
        ) { EmptyView() }
    }
}

// MARK: - Chrome

/// Shared layout for every action card.
private struct ActionCardChrome<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let detail: String?
    let fidelity: ActionFidelity
    let onOpen: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            content()

            FidelityBadge(fidelity: fidelity)
        }
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
    }
}

/// The reminder plan inside a card, with a small heading.
private struct ActionCardPlanSection: View {
    let plan: ReminderPlanPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Divider()
            SectionHeading(text: "Reminder plan")
                .padding(.top, Theme.Spacing.xs)
            ReminderTimelineView(plan: plan, isCompact: true)
        }
    }
}

/// Says what actually happened.
///
/// A card that came from a mock service says "Simulated" and names the service.
/// This is the last line of defence against the UI implying an iPhone did
/// something it did not.
private struct FidelityBadge: View {
    let fidelity: ActionFidelity

    var body: some View {
        switch fidelity {
        case .applied:
            EmptyView()
        case .simulated(let platform):
            badge(
                "Simulated · nothing was scheduled on this device",
                symbol: "testtube.2",
                tint: .secondary
            )
            .accessibilityLabel("Simulated by \(platform). Nothing was scheduled on this device.")
        case .awaitingConfirmation:
            badge("Waiting for your approval", symbol: "hand.raised", tint: .orange)
        case .blocked(let reason):
            badge(reason, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }
}
