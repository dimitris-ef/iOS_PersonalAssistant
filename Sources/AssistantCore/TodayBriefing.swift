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
        /// One occurrence of a recurring responsibility.
        case routine
    }

    /// Why this is on the list, beyond simply being scheduled.
    ///
    /// Presentation reads this to choose a badge — "Blocked", "Recovery",
    /// "Up next" — without re-deriving any of it from the task. Section 67
    /// asks the Today screen to show advanced support meaningfully, and this is
    /// what makes that possible without the view growing its own opinions.
    public enum Emphasis: String, Hashable, Sendable {
        /// Nothing special; it is simply due.
        case none
        /// The most pressing thing right now.
        case upNext
        /// Waiting on an unfinished prerequisite.
        case blocked
        /// Missed and still worth doing.
        case recovery
        /// Its preparation should be starting about now.
        case startNow
        /// Running late against its own plan.
        case behind
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
    public var emphasis: Emphasis
    /// One line saying what it is waiting on, when it is waiting on something.
    public var detail: String?

    public init(
        id: String,
        date: Date,
        title: String,
        kind: Kind,
        reference: Reference,
        isDone: Bool,
        hasPassed: Bool,
        emphasis: Emphasis = .none,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.kind = kind
        self.reference = reference
        self.isDone = isDone
        self.hasPassed = hasPassed
        self.emphasis = emphasis
        self.detail = detail
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
    private let ranker: DailyPriorityRanker

    public init(
        now: Date,
        calendar: Calendar = .current,
        ranker: DailyPriorityRanker = DailyPriorityRanker()
    ) {
        self.now = now
        self.calendar = calendar
        self.ranker = ranker
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

        // Ranking runs over *every* task, not just today's, because whether
        // something is blocked depends on tasks that may be due next week. The
        // day is then filtered out of the ranked result, so a row's emphasis
        // reflects the whole picture rather than one day's slice of it.
        let ranked = ranker.rank(tasks, now: now, calendar: calendar)
        let rankedByID = Dictionary(ranked.map { ($0.task.id, $0) }, uniquingKeysWith: { first, _ in first })
        let topID = ranked.first { !$0.isBlocked }?.task.id

        for task in tasks {
            guard let date = task.anchorDate else { continue }
            guard calendar.isDate(date, inSameDayAs: now) else { continue }
            // A cancelled task is not part of the day, and neither is a skipped
            // occurrence — the user already answered that question. A completed
            // one is, shown as done, because seeing what you finished is part
            // of the point. An expired one stays too: quietly vanishing is how
            // someone learns not to trust the list.
            guard task.status != .cancelled, task.status != .skipped else { continue }

            let entry = rankedByID[task.id]
            items.append(
                TodayItem(
                    id: "task-\(task.id)",
                    date: date,
                    title: task.title,
                    kind: task.isRoutineOccurrence ? .routine : .task,
                    reference: .task(task.id),
                    isDone: task.status == .completed,
                    hasPassed: date < now,
                    emphasis: Self.emphasis(for: task, ranked: entry, isTop: task.id == topID, now: now),
                    detail: entry?.blocked?.summary
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
                guard let reference = Self.reference(for: plan) else { continue }

                items.append(
                    TodayItem(
                        id: "stage-\(reminder.stageID)",
                        date: reminder.fireDate,
                        title: reminder.body,
                        kind: kind,
                        reference: reference,
                        isDone: false,
                        hasPassed: reminder.fireDate < now
                    )
                )
            }
        }

        return TodayBriefing(items: items.sorted { $0.date < $1.date }, now: now)
    }

    /// Why a row is worth looking at.
    ///
    /// One place, so the badge on the Today screen and anything Siri says about
    /// the same item cannot disagree. Order matters: blocked outranks
    /// everything, because a task you cannot start is not "up next" however
    /// urgent it looks.
    private static func emphasis(
        for task: TaskItem,
        ranked: RankedTask?,
        isTop: Bool,
        now: Date
    ) -> TodayItem.Emphasis {
        if ranked?.isBlocked == true { return .blocked }
        if task.status == .missed || task.status == .needsFollowUp { return .recovery }
        if let start = ranked?.preparationStart {
            if start <= now { return .behind }
            if start.timeIntervalSince(now) <= TimeSpan.hours(1) { return .startNow }
        }
        return isTop ? .upNext : .none
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

    /// Where a reminder stage points.
    ///
    /// A plan can also be `.freeform` — a reminder attached to neither a task
    /// nor an event. Those stages are dropped rather than given a made-up
    /// reference: a briefing row the user cannot open is worse than one row
    /// fewer.
    private static func reference(for plan: ReminderPlan) -> TodayItem.Reference? {
        switch plan.subject.reference {
        case .task(let id): return .task(id)
        case .calendarItem(let id): return .event(id)
        case .freeform: return nil
        }
    }
}
