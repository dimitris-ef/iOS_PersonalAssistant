import AssistantDomain
import Foundation
import Observation

/// Screen state for Today.
///
/// The derivations live in `TodayPresenter`; this holds the sheet routing and
/// exposes the presenter's output to the view.
@MainActor
@Observable
final class TodayViewModel {
    var route: DetailRoute?

    private func presenter(for model: AppModel) -> TodayPresenter {
        TodayPresenter(now: model.now, calendar: model.calendar)
    }

    func summary(for model: AppModel) -> String {
        presenter(for: model).summary(
            tasks: model.tasks,
            events: model.events,
            reminderPlans: model.reminderPlans
        )
    }

    func timeline(for model: AppModel) -> [TodayTimelineItem] {
        presenter(for: model).timeline(
            tasks: model.tasks,
            events: model.events,
            reminderPlans: model.reminderPlans
        )
    }

    /// What to do now, ranked by the domain.
    func focus(for model: AppModel) -> [TodayFocusItem] {
        presenter(for: model).focus(tasks: model.tasks)
    }

    func upNext(for model: AppModel) -> UpNextItem? {
        presenter(for: model).upNext(
            tasks: model.tasks,
            events: model.events,
            reminderPlans: model.reminderPlans
        )
    }

    func open(_ reference: TodayTimelineItem.Reference) {
        switch reference {
        case .task(let id): route = .task(id)
        case .event(let id): route = .event(id)
        }
    }

    /// Delivers the next reminder for the up-next item as a simulation, so the
    /// response flow can be exercised without notification delivery existing.
    func simulateNextReminder(for item: UpNextItem, model: AppModel) {
        let matchingPlan: ReminderPlan?
        switch item.reference {
        case .event(let id):
            matchingPlan = model.reminderPlan(forEvent: id)
        case .task(let id):
            matchingPlan = model.reminderPlan(forTask: id)
        }

        func giveUp() {
            model.banner = BannerMessage(
                text: "No reminders are planned for this yet.",
                style: .neutral
            )
        }

        guard let plan = matchingPlan else { return giveUp() }

        let presentation = ReminderPlanPresentation.make(
            from: plan,
            now: model.now,
            calendar: model.calendar
        )

        // Prefer the next stage that has not fired; fall back to the last one
        // so a plan whose stages have all passed can still be previewed.
        guard
            let stage = presentation.stages.first(where: { !$0.hasPassed })
                ?? presentation.stages.last,
            let domainStage = plan.stages.first(where: { $0.id == stage.id })
        else { return giveUp() }

        model.simulateReminder(
            for: SimulatedReminder.from(
                stage: domainStage,
                plan: plan,
                anchor: plan.subject.anchor.date ?? item.date,
                formatter: AppFormatters.shared
            )
        )
    }
}
