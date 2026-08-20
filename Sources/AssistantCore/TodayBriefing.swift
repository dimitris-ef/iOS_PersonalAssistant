import AssistantDomain
import ExecutiveSupport
import Foundation

/// One thing happening today.
///
/// The application-level version of what the Today screen renders. It carries
/// no colours, symbols or formatted strings — those are presentation decisions
/// that differ between a list on screen and a sentence Siri reads aloud, and
/// baking them in here is what would force the two surfaces apart.
public struct TodayItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case task
        case event
        /// "Start getting ready" — the assistant's own addition to the day.
        case preparation
        /// "Leave now."
        case leave
        case reminder
    }

    public enum Reference: Hashable, Sendable {
        case task(TaskItem.ID)
        case event(CalendarItem.ID)
    }

    public var id: String
    public var date: Date
    public var title: String
    public var kind: Kind
    public var reference: Reference
    public var isDone: Bool
    public var hasPassed: Bool

    public init(
        id: String,
        date: Date,
        title: String,
        kind: Kind,
        reference: Reference,
        isDone: Bool,
        hasPassed: Bool
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.kind = kind
        self.reference = reference
        self.isDone = isDone
        self.hasPassed = hasPassed
    }
}

/// The day, ready to be spoken or rendered.
public struct TodayBriefing: Hashable, Sendable {
    public var items: [TodayItem]
    public var now: Date

    public init(items: [TodayItem], now: Date) {
        self.items = items
        self.now = now
    }

    /// What is still ahead.
    public var remaining: [TodayItem] {
        items.filter { !$0.hasPassed && !$0.isDone }
    }

    /// The next thing, if there is one.
    public var next: TodayItem? { remaining.first }

    /// A concise sentence for a system surface.
    ///
    /// Deliberately short, and deliberately built here rather than by asking a
    /// language model. "What's on today" is a question the repositories answer
    /// exactly; routing it through a provider would make a lookup the app can
    /// always do depend on network, credentials and model availability — three
    /// new ways to fail at reciting something already known.
    ///
    /// Three items at most. Siri reading a list of nine is a list nobody
    /// retains, and the app is one tap away for the rest.
    public func spokenSummary(calendar: Calendar = .current) -> String {
        let ahead = remaining
        guard !ahead.isEmpty else {
            return items.isEmpty
                ? "Nothing is scheduled for today."
                : "That's everything for today."
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let described = ahead.prefix(3).map { item -> String in
            "\(item.title) at \(formatter.string(from: item.date))"
        }

        let count = ahead.count
        let lead = count == 1
            ? "One thing left today: "
            : "\(count) things left today. "

        var sentence = lead + described.joined(separator: ", ") + "."
        if count > described.count {
            sentence += " And \(count - described.count) more."
        }
        return sentence
    }
}

/// Builds the day from stored data.
///
/// ## Why this is in the package
///
/// The selection rules — which tasks count as today's, which reminder stages
/// are worth showing, what "has passed" means — were previously only in
/// `TodayPresenter`, inside `iOS/`, where no test can reach them. An App Intent
/// needing the same answer would have meant a second copy, and two copies of
/// "what is on today" drift the first time either is touched.
///
/// So the rules live here and the presenter maps this output into its display
/// types. One definition, two surfaces.
public struct TodayBriefingBuilder: Sendable {
    private let now: Date
    private let calendar: Calendar

    public init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public func build(
        tasks: [TaskItem],
        events: [CalendarItem],
        reminderPlans: [ReminderPlan]
    ) -> TodayBriefing {
        var items: [TodayItem] = []

        for event in events where calendar.isDate(event.start, inSameDayAs: now) {
            items.append(
                TodayItem(
                    id: "event-\(event.id)",
                    date: event.start,
                    title: event.title,
                    kind: .event,
                    reference: .event(event.id),
                    isDone: false,
                    hasPassed: event.start < now
                )
            )
        }

        for task in tasks {
            guard let date = task.timing.anchorDate ?? task.deadline else { continue }
            guard calendar.isDate(date, inSameDayAs: now) else { continue }
            // A cancelled task is not part of the day. A completed one is —
            // it shows as done, because seeing what you finished is part of
            // the point.
            guard task.status != .cancelled else { continue }

            items.append(
                TodayItem(
                    id: "task-\(task.id)",
                    date: date,
                    title: task.title,
                    kind: .task,
                    reference: .task(task.id),
                    isDone: task.status == .completed,
                    hasPassed: date < now
                )
            )
        }

        // Preparation and leave stages are why this is not just a calendar:
        // they are what the assistant added to make the day survivable.
        let resolver = ReminderScheduleResolver(calendar: calendar)
        for plan in reminderPlans {
            // `.distantPast` so stages earlier today are resolved too — the
            // briefing decides what has passed, the resolver should not filter
            // them out first.
            for reminder in resolver.resolve(plan: plan, now: .distantPast) {
                guard calendar.isDate(reminder.fireDate, inSameDayAs: now) else { continue }
                guard let kind = Self.kind(for: reminder.kind) else { continue }

                items.append(
                    TodayItem(
                        id: "stage-\(reminder.stageID)",
                        date: reminder.fireDate,
                        title: reminder.body,
                        kind: kind,
                        reference: Self.reference(for: plan),
                        isDone: false,
                        hasPassed: reminder.fireDate < now
                    )
                )
            }
        }

        return TodayBriefing(items: items.sorted { $0.date < $1.date }, now: now)
    }

    /// Only stages representing something the user has to *do* earn a place.
    ///
    /// Advance notices and same-day heads-ups are the assistant talking, not
    /// the day happening, and a briefing padded with them buries the two lines
    /// that matter.
    private static func kind(for stage: ReminderStageKind) -> TodayItem.Kind? {
        switch stage {
        case .preparation: return .preparation
        case .leave: return .leave
        case .finalCall: return .reminder
        case .advanceNotice, .morningOf, .nudge, .followUp: return nil
        }
    }

    private static func reference(for plan: ReminderPlan) -> TodayItem.Reference {
        switch plan.subject.reference {
        case .task(let id): return .task(id)
        case .event(let id): return .event(id)
        }
    }
}
