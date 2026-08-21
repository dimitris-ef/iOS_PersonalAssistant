import AssistantDomain
import Foundation

/// How well the plan is going.
public enum PreparationRisk: Hashable, Sendable {
    /// There is still enough time for everything.
    case onTrack
    /// Started late. `behindBy` is how far.
    case behind(TimeInterval)
    /// Not enough time remains even for the required steps.
    /// `shortBy` is the gap.
    case cannotMakeIt(shortBy: TimeInterval)

    public var isBehind: Bool {
        if case .onTrack = self { return false }
        return true
    }
}

/// One step with a moment attached.
public struct ScheduledPreparationStep: Hashable, Sendable, Identifiable {
    public var id: PreparationStep.ID { step.id }
    public var step: PreparationStep
    public var start: Date
    public var end: Date
    /// True when compression removed this step from the plan.
    public var isDropped: Bool

    public init(step: PreparationStep, start: Date, end: Date, isDropped: Bool = false) {
        self.step = step
        self.start = start
        self.end = end
        self.isDropped = isDropped
    }
}

/// When to start, when to leave, and what to do in between.
public struct PreparationTimeline: Hashable, Sendable {
    /// The thing being prepared for.
    public var anchor: Date
    /// When to begin the first step.
    public var startAt: Date
    /// When to walk out of the door. Equal to `anchor` when there is no travel.
    public var leaveAt: Date
    /// Travel, buffer and steps, in order.
    public var steps: [ScheduledPreparationStep]
    public var risk: PreparationRisk
    /// True when compression had to remove steps to make the plan fit.
    public var isCompressed: Bool

    public init(
        anchor: Date,
        startAt: Date,
        leaveAt: Date,
        steps: [ScheduledPreparationStep],
        risk: PreparationRisk = .onTrack,
        isCompressed: Bool = false
    ) {
        self.anchor = anchor
        self.startAt = startAt
        self.leaveAt = leaveAt
        self.steps = steps
        self.risk = risk
        self.isCompressed = isCompressed
    }

    /// The steps still in the plan, in order.
    public var keptSteps: [ScheduledPreparationStep] {
        steps.filter { !$0.isDropped }
    }

    /// The steps compression removed.
    public var droppedSteps: [ScheduledPreparationStep] {
        steps.filter(\.isDropped)
    }

    /// The next thing to actually do.
    public var nextStep: ScheduledPreparationStep? {
        keptSteps.first { !$0.step.isCompleted }
    }
}

/// How much slack to leave, and how hard to compress.
public struct PreparationPolicy: Hashable, Sendable {
    /// Slack between arriving and the thing starting.
    ///
    /// One value with an importance multiplier rather than a number repeated in
    /// four places — section 23's actual complaint. Ten minutes for something
    /// normal; more when being late matters more.
    public var buffer: TimeInterval
    /// How much the buffer grows for important commitments.
    public var importantBufferMultiplier: Double
    /// The smallest buffer compression may squeeze down to.
    ///
    /// Not zero. A plan that has the user arriving at the exact second the
    /// appointment begins is a plan that fails, and telling someone it fits is
    /// worse than telling them it does not.
    public var minimumBuffer: TimeInterval
    /// Fallback when a step carries no estimate of its own.
    public var defaultStepDuration: TimeInterval

    public init(
        buffer: TimeInterval = TimeSpan.minutes(10),
        importantBufferMultiplier: Double = 1.5,
        minimumBuffer: TimeInterval = TimeSpan.minutes(2),
        defaultStepDuration: TimeInterval = TimeSpan.minutes(5)
    ) {
        self.buffer = buffer
        self.importantBufferMultiplier = importantBufferMultiplier
        self.minimumBuffer = minimumBuffer
        self.defaultStepDuration = defaultStepDuration
    }

    public static let `default` = PreparationPolicy()

    public func buffer(for importance: Importance) -> TimeInterval {
        importance >= .high ? buffer * importantBufferMultiplier : buffer
    }
}

/// Turns "work starts at four" into "start getting ready at 2:35".
///
/// ## The calculation
///
/// ```
/// anchor            16:00   the thing itself
///  − buffer          10m    slack, so arriving is not a photo finish
///  − travel          30m
/// = leave           15:20
///  − preparation     45m    the steps, or the stated duration
/// = start           14:35
/// ```
///
/// Deterministic, offline, and the same every time. Section 58 makes this a
/// hard requirement and it is the right one: a person who is already late does
/// not need the answer to depend on a network round trip.
///
/// ## Compression
///
/// The interesting case is not the plan — it is what happens twenty minutes
/// after the plan was ignored. Repeating "start getting ready at 2:35" at 2:55
/// is worse than useless: it is visibly wrong, and being visibly wrong is how
/// an assistant loses the benefit of the doubt. So when the remaining time no
/// longer fits, the plan is rebuilt against the time that is actually left —
/// optional steps first to go, then recommended, and the buffer squeezed to its
/// floor before anything required is touched.
public struct PreparationPlanner: Sendable {
    public let policy: PreparationPolicy

    public init(policy: PreparationPolicy = .default) {
        self.policy = policy
    }

    /// The timeline for a task, from now.
    ///
    /// `now` matters even for a plan that has not started: it is what decides
    /// whether this is a schedule or a rescue.
    public func timeline(
        anchor: Date,
        steps: [PreparationStep],
        travelDuration: TimeInterval?,
        preparationDuration: TimeInterval?,
        importance: Importance,
        now: Date
    ) -> PreparationTimeline {
        let travel = max(0, travelDuration ?? 0)
        let buffer = policy.buffer(for: importance)
        let leaveAt = anchor.addingTimeInterval(-(travel + buffer))

        let ordered = steps.ordered
        // Steps win over a single duration when there are any: they say the
        // same thing with more detail. The bare duration is the fallback for a
        // task nobody has broken down.
        let required = ordered.isEmpty
            ? max(0, preparationDuration ?? 0)
            : ordered.reduce(0) { $0 + duration(of: $1) }

        let idealStart = leaveAt.addingTimeInterval(-required)
        let remaining = leaveAt.timeIntervalSince(now)

        // Still early, or exactly on time: the plan as designed.
        if now <= idealStart || remaining >= required {
            return PreparationTimeline(
                anchor: anchor,
                startAt: max(idealStart, now),
                leaveAt: leaveAt,
                steps: schedule(ordered, from: max(idealStart, now)),
                risk: now <= idealStart ? .onTrack : .behind(now.timeIntervalSince(idealStart))
            )
        }

        return compressed(
            anchor: anchor,
            steps: ordered,
            leaveAt: leaveAt,
            travel: travel,
            buffer: buffer,
            behindBy: now.timeIntervalSince(idealStart),
            now: now
        )
    }

    /// Convenience for a task that already carries everything needed.
    public func timeline(for task: TaskItem, now: Date) -> PreparationTimeline? {
        guard let anchor = task.anchorDate else { return nil }
        return timeline(
            anchor: anchor,
            steps: task.preparationSteps,
            travelDuration: task.travelDuration,
            preparationDuration: task.preparationDuration,
            importance: task.importance,
            now: now
        )
    }

    // MARK: Compression

    /// Rebuilds the plan against the time that is left.
    ///
    /// Order of sacrifice: optional steps, then recommended, then the buffer
    /// down to its floor. Required steps are never dropped — if they do not fit
    /// even then, the answer is `cannotMakeIt` and the number of minutes short,
    /// because "you are eight minutes short" is something a person can act on
    /// and "you are late" is not.
    private func compressed(
        anchor: Date,
        steps: [PreparationStep],
        leaveAt: Date,
        travel: TimeInterval,
        buffer: TimeInterval,
        behindBy: TimeInterval,
        now: Date
    ) -> PreparationTimeline {
        var kept = steps.filter { !$0.isCompleted }
        var dropped: [PreparationStep] = []
        var remaining = leaveAt.timeIntervalSince(now)

        // Drop by necessity, least essential first, and only as far as needed.
        for necessity in [StepNecessity.optional, .recommended] {
            while remaining < kept.reduce(0, { $0 + duration(of: $1) }),
                  let index = kept.lastIndex(where: { $0.necessity == necessity }) {
                dropped.append(kept.remove(at: index))
            }
        }

        var leave = leaveAt
        var needed = kept.reduce(0) { $0 + duration(of: $1) }

        // Still short: spend the buffer, down to the floor and no further.
        if remaining < needed {
            let recoverable = max(0, buffer - policy.minimumBuffer)
            let borrowed = min(recoverable, needed - remaining)
            leave = leaveAt.addingTimeInterval(borrowed)
            remaining += borrowed
        }

        needed = kept.reduce(0) { $0 + duration(of: $1) }
        let risk: PreparationRisk = remaining < needed
            ? .cannotMakeIt(shortBy: needed - remaining)
            : .behind(behindBy)

        // Everything starts now, because it does. The completed steps stay in
        // the list so the timeline still describes the whole plan.
        let completed = steps.filter(\.isCompleted)
        var scheduled = schedule(completed, from: now).map { entry -> ScheduledPreparationStep in
            var entry = entry
            entry.isDropped = false
            return entry
        }
        scheduled += schedule(kept, from: now)
        scheduled += dropped.map {
            ScheduledPreparationStep(step: $0, start: now, end: now, isDropped: true)
        }

        return PreparationTimeline(
            anchor: anchor,
            startAt: now,
            leaveAt: leave,
            steps: scheduled,
            risk: risk,
            isCompressed: !dropped.isEmpty || leave != leaveAt
        )
    }

    // MARK: Helpers

    private func schedule(_ steps: [PreparationStep], from start: Date) -> [ScheduledPreparationStep] {
        var cursor = start
        return steps.map { step in
            let end = cursor.addingTimeInterval(duration(of: step))
            defer { cursor = end }
            return ScheduledPreparationStep(step: step, start: cursor, end: end)
        }
    }

    private func duration(of step: PreparationStep) -> TimeInterval {
        step.estimatedDuration > 0 ? step.estimatedDuration : policy.defaultStepDuration
    }
}
