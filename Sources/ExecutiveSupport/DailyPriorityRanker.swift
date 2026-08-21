import AssistantDomain
import Foundation

/// Why something ranked where it did.
///
/// Kept as separate terms rather than one number because a single number is
/// untestable and undebuggable: when the wrong thing is at the top, "score 4.7"
/// says nothing and "deadline 3.0, overdue 0.0, blocked −2.0" says exactly
/// which rule misfired.
///
/// Not shown to the user. Section 73 is right that a person who asked what to
/// do next does not want arithmetic; they want the answer. This is for tests,
/// for logs, and for the day somebody has to explain the ordering.
public struct PriorityScoreBreakdown: Hashable, Sendable {
    /// How soon it matters.
    public var urgency: Double
    /// How much it matters.
    public var importance: Double
    /// Extra weight as a hard deadline closes in.
    public var deadline: Double
    /// Negative when blocked by unfinished prerequisites.
    public var dependency: Double
    /// Weight for something missed that can still be rescued.
    public var recovery: Double
    /// Weight for something whose preparation should be starting about now.
    public var preparation: Double
    /// Weight for being past due — bounded, so it cannot dominate forever.
    public var overdue: Double
    /// Weight for work already under way, so starting something is rewarded.
    public var momentum: Double

    public init(
        urgency: Double = 0,
        importance: Double = 0,
        deadline: Double = 0,
        dependency: Double = 0,
        recovery: Double = 0,
        preparation: Double = 0,
        overdue: Double = 0,
        momentum: Double = 0
    ) {
        self.urgency = urgency
        self.importance = importance
        self.deadline = deadline
        self.dependency = dependency
        self.recovery = recovery
        self.preparation = preparation
        self.overdue = overdue
        self.momentum = momentum
    }

    public var total: Double {
        urgency + importance + deadline + dependency + recovery + preparation + overdue + momentum
    }
}

/// One task, ranked, with everything the UI needs to explain itself.
public struct RankedTask: Identifiable, Hashable, Sendable {
    public var id: TaskItem.ID { task.id }
    public var task: TaskItem
    public var score: PriorityScoreBreakdown
    /// Set when unfinished prerequisites stand in the way.
    public var blocked: BlockedReason?
    /// When preparation for this should begin, when it has any.
    public var preparationStart: Date?

    public init(
        task: TaskItem,
        score: PriorityScoreBreakdown,
        blocked: BlockedReason? = nil,
        preparationStart: Date? = nil
    ) {
        self.task = task
        self.score = score
        self.blocked = blocked
        self.preparationStart = preparationStart
    }

    public var isBlocked: Bool { blocked != nil }
}

/// Decides what deserves attention now.
///
/// ## Why this is not in the view
///
/// Because three surfaces need the same answer — the Today screen, Siri's
/// "what should I do now", and the assistant's own sense of what to bring up —
/// and because the interesting rules are not sortable by a keypath. "A blocked
/// task never outranks the thing blocking it" is not a comparator; it is a
/// constraint applied after scoring. Section 72's instruction to keep sorting
/// out of SwiftUI is really an instruction to keep it somewhere a test can
/// reach, and this is that place.
///
/// Deterministic and offline. The same list, the same clock, the same order,
/// every time.
public struct DailyPriorityRanker: Sendable {
    /// The weights, gathered so they can be read together and tuned in one
    /// place rather than discovered one magic number at a time.
    public struct Weights: Hashable, Sendable {
        public var importance: Double
        public var urgencyWithinHours: Double
        public var urgencyCeiling: Double
        public var deadlineToday: Double
        public var blockedPenalty: Double
        public var recovery: Double
        public var preparationImminent: Double
        public var overdueCeiling: Double
        public var overduePerDay: Double
        public var inProgress: Double

        public init(
            importance: Double = 1.0,
            urgencyWithinHours: Double = 6,
            urgencyCeiling: Double = 4.0,
            deadlineToday: Double = 1.5,
            blockedPenalty: Double = -6.0,
            recovery: Double = 1.5,
            preparationImminent: Double = 5.0,
            overdueCeiling: Double = 2.5,
            overduePerDay: Double = 0.5,
            inProgress: Double = 1.0
        ) {
            self.importance = importance
            self.urgencyWithinHours = urgencyWithinHours
            self.urgencyCeiling = urgencyCeiling
            self.deadlineToday = deadlineToday
            self.blockedPenalty = blockedPenalty
            self.recovery = recovery
            self.preparationImminent = preparationImminent
            self.overdueCeiling = overdueCeiling
            self.overduePerDay = overduePerDay
            self.inProgress = inProgress
        }

        public static let `default` = Weights()
    }

    public let weights: Weights
    private let preparation: PreparationPlanner

    public init(
        weights: Weights = .default,
        preparation: PreparationPlanner = PreparationPlanner()
    ) {
        self.weights = weights
        self.preparation = preparation
    }

    /// The tasks worth attention, most pressing first.
    ///
    /// Settled tasks drop out entirely: a completed, skipped or expired thing
    /// is not competing for anyone's attention.
    public func rank(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [RankedTask] {
        let open = tasks.filter { !$0.status.isTerminal }
        let graph = TaskDependencyGraph(tasks: tasks)

        let scored = open.map { task -> RankedTask in
            let blocked = graph.blockedReason(for: task)
            let timeline = preparation.timeline(for: task, now: now)
            return RankedTask(
                task: task,
                score: score(task, blocked: blocked, timeline: timeline, now: now, calendar: calendar),
                blocked: blocked,
                preparationStart: timeline?.startAt
            )
        }

        let ordered = scored.sorted { lhs, rhs in
            if lhs.score.total != rhs.score.total { return lhs.score.total > rhs.score.total }
            // Stable tie-break: sooner first, then by title, so the same input
            // never renders in two different orders.
            let left = lhs.task.anchorDate ?? .distantFuture
            let right = rhs.task.anchorDate ?? .distantFuture
            if left != right { return left < right }
            return lhs.task.title < rhs.task.title
        }

        return liftPrerequisites(ordered, graph: graph)
    }

    // MARK: Scoring

    private func score(
        _ task: TaskItem,
        blocked: BlockedReason?,
        timeline: PreparationTimeline?,
        now: Date,
        calendar: Calendar
    ) -> PriorityScoreBreakdown {
        var score = PriorityScoreBreakdown()

        score.importance = Double(task.importance.rank) * weights.importance

        if let anchor = task.anchorDate {
            let hoursAway = anchor.timeIntervalSince(now) / TimeSpan.hour

            if hoursAway >= 0 {
                // Rises as the moment approaches, flat beyond the horizon so
                // next month's deadline does not compete with this afternoon's.
                let closeness = max(0, weights.urgencyWithinHours - hoursAway) / weights.urgencyWithinHours
                score.urgency = closeness * weights.urgencyCeiling

                if calendar.isDate(anchor, inSameDayAs: now) {
                    score.deadline = weights.deadlineToday
                }
            } else {
                // Overdue. Section 35: this must not become a permanent throne.
                // The weight grows for a couple of days and then stops, so a
                // stale errand keeps nagging gently while a fresh urgent thing
                // still wins.
                let daysOverdue = -hoursAway / 24
                score.overdue = min(
                    weights.overdueCeiling,
                    daysOverdue * weights.overduePerDay + weights.overduePerDay
                )
            }
        }

        // Missed but rescuable: worth surfacing, not worth outranking the thing
        // happening in ten minutes.
        if task.status == .missed || task.status == .needsFollowUp {
            score.recovery = weights.recovery
        }

        if task.status == .inProgress {
            score.momentum = weights.inProgress
        }

        // The case section 33 turns on. When preparation should be starting
        // about now, this is *the* thing to do, even though the appointment
        // itself is hours away and the bill is due today.
        if let timeline, !task.status.isTerminal {
            let untilStart = timeline.startAt.timeIntervalSince(now)
            if untilStart <= TimeSpan.hours(1) {
                score.preparation = weights.preparationImminent
            }
            if timeline.risk.isBehind {
                score.preparation += weights.recovery
            }
        }

        if blocked != nil {
            // Large and negative rather than exclusion. A blocked task still
            // belongs on the list — seeing that it is waiting is information —
            // it just has no business being at the top.
            score.dependency = weights.blockedPenalty
        }

        return score
    }

    /// Guarantees no task appears above one it is waiting on.
    ///
    /// The penalty alone is not enough, and section 93 is explicit about the
    /// case: a blocked task with a deadline this afternoon can still outscore
    /// the prerequisite that is due next week. Telling someone to submit the
    /// paperwork above telling them to finish it is advice they cannot follow.
    ///
    /// A stable pass: walk the list, and whenever a task's open prerequisites
    /// sit below it, move them up immediately before it. Terminates because
    /// every task is emitted exactly once, and the graph has already been
    /// checked for cycles at the point edges were created.
    private func liftPrerequisites(_ ranked: [RankedTask], graph: TaskDependencyGraph) -> [RankedTask] {
        let byID = Dictionary(ranked.map { ($0.task.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emitted: Set<TaskItem.ID> = []
        var result: [RankedTask] = []

        func emit(_ entry: RankedTask, depth: Int) {
            guard emitted.insert(entry.task.id).inserted else { return }
            // Depth guard: belt and braces against a cycle that predates
            // validation. Without it a malformed graph would recurse forever.
            if depth < 16 {
                for prerequisite in graph.openPrerequisites(of: entry.task) {
                    guard let ranked = byID[prerequisite.id] else { continue }
                    emit(ranked, depth: depth + 1)
                }
            }
            result.append(entry)
        }

        for entry in ranked {
            emit(entry, depth: 0)
        }
        return result
    }
}
