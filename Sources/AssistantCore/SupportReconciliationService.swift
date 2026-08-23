import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation

/// What one reconciliation pass did.
///
/// Counts and identifiers, never task titles or reminder text (section 120).
/// This is what a development log and the debug diagnostics screen print, and
/// a log line naming what somebody is being reminded about is the most private
/// thing this app could emit.
public struct SupportReconciliationReport: Hashable, Sendable {
    /// Distinct per pass, so interleaved logs from a foreground pass and a
    /// background refresh can be told apart.
    public var passID: UUID
    public var tasksEvaluated: Int
    public var missedStages: Int
    /// Stages recorded as missed without each driving a planning round.
    public var absorbedStages: Int
    public var followUpsGenerated: Int
    public var scheduled: Int
    public var cancelled: Int
    /// Requests already correct, left completely alone.
    public var unchanged: Int
    public var schedulingFailures: Int
    /// True when notifications cannot be delivered at all.
    public var deliveryUnavailable: Bool
    /// Routine occurrences created or recovered in the same pass.
    public var routineOccurrencesCreated: Int
    public var routineOccurrencesRecovered: Int
    /// True when the pass stopped early because it ran out of budget.
    public var wasTruncated: Bool
    /// True when the pass was cancelled — background expiry, or teardown.
    public var wasCancelled: Bool
    public var duration: TimeInterval

    public init(
        passID: UUID = UUID(),
        tasksEvaluated: Int = 0,
        missedStages: Int = 0,
        absorbedStages: Int = 0,
        followUpsGenerated: Int = 0,
        scheduled: Int = 0,
        cancelled: Int = 0,
        unchanged: Int = 0,
        schedulingFailures: Int = 0,
        deliveryUnavailable: Bool = false,
        routineOccurrencesCreated: Int = 0,
        routineOccurrencesRecovered: Int = 0,
        wasTruncated: Bool = false,
        wasCancelled: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.passID = passID
        self.tasksEvaluated = tasksEvaluated
        self.missedStages = missedStages
        self.absorbedStages = absorbedStages
        self.followUpsGenerated = followUpsGenerated
        self.scheduled = scheduled
        self.cancelled = cancelled
        self.unchanged = unchanged
        self.schedulingFailures = schedulingFailures
        self.deliveryUnavailable = deliveryUnavailable
        self.routineOccurrencesCreated = routineOccurrencesCreated
        self.routineOccurrencesRecovered = routineOccurrencesRecovered
        self.wasTruncated = wasTruncated
        self.wasCancelled = wasCancelled
        self.duration = duration
    }

    /// True when anything the user could notice changed.
    public var didChange: Bool {
        missedStages > 0 || followUpsGenerated > 0 || scheduled > 0 || cancelled > 0
            || routineOccurrencesCreated > 0 || routineOccurrencesRecovered > 0
    }

    /// One line for the debug diagnostics screen (section 121).
    public var summary: String {
        "\(tasksEvaluated) tasks · \(missedStages) missed · \(followUpsGenerated) follow-ups · "
            + "\(scheduled) scheduled · \(cancelled) cancelled · \(unchanged) unchanged"
    }
}

/// Why a reconciliation pass was asked for.
///
/// Recorded rather than acted on differently — every trigger runs the same pass
/// — because "the background refresh found four missed reminders" is a
/// different diagnostic story from "the user opened the app and it found four".
public enum ReconciliationTrigger: String, Hashable, Sendable {
    case launch
    case foreground
    case backgroundRefresh
    case notificationAction
    case manual
}

/// Works out what happened while the app was not running, and puts it right.
///
/// ## The problem
///
/// iOS gives this app no general way to run. It is launched, it is suspended,
/// it is terminated, and none of that is under its control — so an assistant
/// built on in-memory timers is an assistant that stops supporting someone the
/// moment they switch apps. Section 2's answer is the only one available:
/// **persisted domain state is the source of truth**, iOS is asked to deliver
/// the user-facing part, and when the process next gets to run it reconstructs
/// what should have happened from what it stored.
///
/// ## The order, and why it is fixed
///
/// Section 59, and every step is where it is for a reason:
///
/// 1. **Routines first.** A recurring responsibility whose moment passed while
///    the app was closed has to *exist as a task* before anything can notice it
///    was missed. Generating occurrences after reconciling reminders means
///    yesterday's bin night is found an hour later, by accident.
/// 2. **Load tasks.** Outstanding only — a completed task needs no support.
/// 3. **Detect and transition.** Overdue pending stages become missed, bounded
///    and compressed (sections 69–72).
/// 4. **Plan.** `SupportPlanner`, through the existing coordinator. This
///    service never decides *what support to give* — section 33: reconciliation
///    answers "what happened while we were away", planning answers "what now",
///    and merging them would put escalation policy in two places.
/// 5. **Persist.** Everything, before a single platform call.
/// 6. **Diff and apply.** Desired schedule versus what iOS actually holds.
///
/// Step 5 before step 6 is section 60: if the process dies between them, the
/// plan is on disk and the next pass schedules it. The other order would leave
/// iOS holding a reminder for a stage that does not exist.
///
/// ## What it never does
///
/// Calls an AI provider. Section 44 is a hard requirement and this file has no
/// way to break it: `AssistantCore`'s reconciliation path takes repositories, a
/// platform service, a clock and pure policies. There is no `AIProviderRegistry`
/// in scope, which is a stronger guarantee than a promise not to use one.
public actor SupportReconciliationService {
    private let repositories: AssistantRepositories
    private let services: PlatformServices
    private let routines: RoutineService
    private let scheduler: PlatformScheduleReconciler
    private let coordinator: FollowUpCoordinator
    private let policy: SupportCatchUpPolicy
    private let dateProvider: any DateProvider
    private let logger: (any ReconciliationLogger)?

    /// The pass currently running, if any. The whole of single-flight.
    private var inFlight: Task<SupportReconciliationReport, Error>?

    public init(
        repositories: AssistantRepositories,
        services: PlatformServices,
        routines: RoutineService,
        dateProvider: any DateProvider = SystemDateProvider(),
        policy: SupportCatchUpPolicy = .default,
        timing: FollowUpTiming = .default,
        logger: (any ReconciliationLogger)? = nil
    ) {
        self.repositories = repositories
        self.services = services
        self.routines = routines
        self.dateProvider = dateProvider
        self.policy = policy
        self.logger = logger
        self.coordinator = FollowUpCoordinator(planner: DefaultSupportPlanner(timing: timing))
        self.scheduler = PlatformScheduleReconciler(
            repositories: repositories,
            services: services,
            policy: policy,
            dateProvider: dateProvider
        )
    }

    /// Runs a pass, or joins the one already running.
    ///
    /// ## Single-flight
    ///
    /// Sections 83 and 84. Two triggers routinely overlap: the app becomes
    /// active at the same moment a background refresh fires, or a notification
    /// action launches the app and the launch pass starts alongside it. Running
    /// both would have two passes reading the same overdue stage, both deciding
    /// it is missed, and both generating a follow-up.
    ///
    /// A second caller *awaits the first* rather than being turned away. Being
    /// told "someone else is doing it" would be useless to a caller that needs
    /// the state settled before it draws a screen — and it would make the
    /// background-refresh path silently skip its work whenever the user
    /// happened to be looking at the app.
    @discardableResult
    public func reconcile(
        trigger: ReconciliationTrigger = .foreground
    ) async throws -> SupportReconciliationReport {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await runPass(trigger: trigger) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Stops the pass in flight.
    ///
    /// Section 42 and 85. Called when a `BGAppRefreshTask` is about to expire:
    /// everything already persisted stays persisted — each step commits before
    /// the next begins — and the next pass picks up from there. What must not
    /// happen is the work continuing after iOS has stopped listening.
    public func cancel() {
        inFlight?.cancel()
    }

    // MARK: The pass

    private func runPass(trigger: ReconciliationTrigger) async throws -> SupportReconciliationReport {
        let started = Date()
        var report = SupportReconciliationReport()
        let now = dateProvider.now

        // 1. Routines. Occurrences that should exist by now must exist before
        //    anything looks for missed reminders (section 34).
        do {
            let recurring = try await routines.reconcileAll()
            report.routineOccurrencesCreated = recurring.created.count
            report.routineOccurrencesRecovered = recurring.recovering.count
        } catch {
            // A routine failure must not stop reminder recovery: the two are
            // independent, and the reminders are the part the user is waiting
            // on.
            logger?.reconciliationFailed(passID: report.passID, stage: "routines")
        }

        try Task.checkCancellation()

        // 2–5. Tasks: detect, transition, plan, persist.
        let outstanding = try await repositories.tasks.tasks(matching: .outstanding)
        let considered = outstanding.prefix(policy.maximumTasksPerPass)
        report.wasTruncated = outstanding.count > considered.count

        for task in considered {
            do {
                try Task.checkCancellation()
            } catch {
                report.wasCancelled = true
                break
            }

            report.tasksEvaluated += 1
            guard
                let planID = task.reminderPlanID,
                let plan = try await repositories.reminderPlans.plan(id: planID)
            else { continue }

            let outcome = coordinator.reconcile(
                task: task,
                plan: plan,
                context: try await planningContext(now: now),
                policy: policy
            )
            guard outcome.didChange else { continue }

            report.missedStages += outcome.catchUp.missedStages.count
            report.absorbedStages += outcome.catchUp.absorbedCount
            report.followUpsGenerated += outcome.schedule.count

            // Persisted before anything touches the OS (section 60). If the
            // process dies here, the plan is on disk and the next pass
            // schedules it; the other order would leave iOS holding a reminder
            // for a stage nothing knows about.
            try await repositories.reminderPlans.save(outcome.plan)
            try await repositories.tasks.save(outcome.task)
        }

        try Task.checkCancellation()

        // 6. The OS schedule, brought in line with what is now on disk.
        let scheduleReport = try await scheduler.apply(now: now)
        report.scheduled = scheduleReport.scheduled
        report.cancelled = scheduleReport.cancelled
        report.unchanged = scheduleReport.unchanged
        report.schedulingFailures = scheduleReport.failures
        report.deliveryUnavailable = scheduleReport.deliveryUnavailable

        // Housekeeping: handled-action rows that can no longer be re-delivered.
        try? await repositories.supportActions.prune(
            before: now.addingTimeInterval(-Self.actionRetention)
        )

        report.duration = Date().timeIntervalSince(started)
        logger?.reconciliationFinished(report, trigger: trigger)
        return report
    }

    /// How long a handled-action record is worth keeping.
    ///
    /// Long enough to cover any plausible duplicate — a notification the user
    /// left sitting for days and then answered — and short enough that the
    /// table does not grow without bound.
    static let actionRetention = TimeSpan.days(30)

    private func planningContext(now: Date) async throws -> SupportPlanningContext {
        SupportPlanningContext(
            profile: try await repositories.profile.profile(),
            preferences: try await repositories.settings.settings().support,
            now: now,
            calendar: dateProvider.calendar
        )
    }
}

/// Where a reconciliation pass reports itself.
///
/// A protocol rather than a print, because the one thing that must not happen
/// is task titles and reminder text reaching a log (section 120). The report
/// this receives is counts and identifiers only, by construction.
public protocol ReconciliationLogger: Sendable {
    func reconciliationFinished(
        _ report: SupportReconciliationReport,
        trigger: ReconciliationTrigger
    )
    func reconciliationFailed(passID: UUID, stage: String)
}
