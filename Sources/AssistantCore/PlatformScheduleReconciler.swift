import AssistantDomain
import AssistantPersistence
import ExecutiveSupport
import Foundation

/// What bringing the OS schedule in line with the database cost.
public struct ScheduleApplicationReport: Hashable, Sendable {
    public var scheduled: Int
    public var cancelled: Int
    public var unchanged: Int
    public var failures: Int
    /// True when notifications cannot be delivered at all — permission is off.
    public var deliveryUnavailable: Bool

    public init(
        scheduled: Int = 0,
        cancelled: Int = 0,
        unchanged: Int = 0,
        failures: Int = 0,
        deliveryUnavailable: Bool = false
    ) {
        self.scheduled = scheduled
        self.cancelled = cancelled
        self.unchanged = unchanged
        self.failures = failures
        self.deliveryUnavailable = deliveryUnavailable
    }
}

/// Makes what iOS is holding match what the database says it should hold.
///
/// ## Domain wins
///
/// Section 56. When the two disagree, the persisted plan decides. An unresolved
/// stage with no matching OS request gets one; a completed task's leftover
/// request is cancelled (section 57); a routine that has been switched off has
/// its future occurrences withdrawn (section 58). What never happens is the
/// reverse — a pending notification is not evidence that a task is unfinished,
/// and treating it that way would let a stale request reopen work the user has
/// already done.
///
/// ## Why the diff matters
///
/// Section 29 rules out clearing everything and re-adding. A diff means a pass
/// over an unchanged store makes *zero* platform calls, which is what makes
/// running this on every foreground affordable — and it means the app never
/// has a window with no reminders scheduled at all.
public struct PlatformScheduleReconciler: Sendable {
    private let repositories: AssistantRepositories
    private let services: PlatformServices
    private let policy: SupportCatchUpPolicy
    private let dateProvider: any DateProvider

    public init(
        repositories: AssistantRepositories,
        services: PlatformServices,
        policy: SupportCatchUpPolicy = .default,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.repositories = repositories
        self.services = services
        self.policy = policy
        self.dateProvider = dateProvider
    }

    /// Computes the desired schedule, diffs it, and applies the difference.
    @discardableResult
    public func apply(now: Date) async throws -> ScheduleApplicationReport {
        var report = ScheduleApplicationReport()

        let plans = try await deliverablePlans()
        let desired = plans.flatMap { desiredEntries(for: $0.plan, taskID: $0.taskID, now: now) }
        let existing = try await existingEntries()

        let diff = PlatformScheduleDiff.between(desired: desired, existing: existing)
        report.unchanged = diff.unchanged.count

        // Withdrawals first. A stage whose time moved is cancelled and re-added,
        // and doing it the other way round would have the cancellation delete
        // the request that had just replaced it — the identifier is the same.
        for stageID in diff.toCancel {
            await withdraw(stageID: stageID)
            report.cancelled += 1
        }

        // Written back per plan, not per request: a plan whose three stages all
        // scheduled successfully is one save.
        var deliveryUpdates: [ReminderPlan.ID: [ReminderStage.ID: StageDelivery]] = [:]

        for entry in diff.toSchedule {
            let result = await schedule(entry)
            switch result {
            case .scheduled(let delivery):
                report.scheduled += 1
                deliveryUpdates[entry.planID, default: [:]][entry.stageID] = delivery
            case .failed(let delivery, let permanent):
                report.failures += 1
                report.deliveryUnavailable = report.deliveryUnavailable || permanent
                deliveryUpdates[entry.planID, default: [:]][entry.stageID] = delivery
            }
        }

        // Section 61: the domain reminder survives a scheduling failure. What
        // is recorded is that delivery did not happen, which is what the next
        // pass reads to decide whether to retry — and what the Settings screen
        // reads to stop claiming a reminder will fire when it will not.
        try await persistDeliveryStates(deliveryUpdates)

        return report
    }

    // MARK: Desired

    private func deliverablePlans() async throws -> [(taskID: TaskItem.ID, plan: ReminderPlan)] {
        var result: [(TaskItem.ID, ReminderPlan)] = []
        for task in try await repositories.tasks.tasks(matching: .outstanding) {
            guard
                let planID = task.reminderPlanID,
                let plan = try await repositories.reminderPlans.plan(id: planID)
            else { continue }
            result.append((task.id, plan))
        }
        return result
    }

    /// The requests this plan wants iOS to be holding.
    ///
    /// Bounded by the rolling horizon (sections 87–90): stages further out than
    /// the policy allows are left in the plan and picked up by a later pass. A
    /// design that pre-scheduled every adaptive escalation for the next month
    /// would fill the pending queue with requests that are mostly obsolete by
    /// the time they fire.
    func desiredEntries(
        for plan: ReminderPlan,
        taskID: TaskItem.ID,
        now: Date
    ) -> [DesiredScheduleEntry] {
        plan.deliverableStages.compactMap { stage in
            guard let fireDate = stage.scheduledFor else { return nil }
            // Already past. Reconciliation has just marked anything genuinely
            // overdue as missed, so what reaches here is inside the grace
            // window — and asking iOS to deliver something in the past would
            // fire it immediately, which is not what a two-minute grace period
            // is for.
            guard fireDate > now else { return nil }
            guard policy.isWithinHorizon(fireDate, from: now) else { return nil }
            guard policy.permitsAnotherAttempt(stage.delivery)
                || stage.delivery.state == .scheduled
            else { return nil }

            return DesiredScheduleEntry(
                stageID: stage.id,
                taskID: taskID,
                planID: plan.id,
                fireDate: fireDate,
                channel: stage.channel,
                title: plan.subject.title,
                body: stage.message,
                escalation: stage.escalation,
                requiresConfirmation: stage.requiresConfirmation,
                revision: plan.revision
            )
        }
    }

    // MARK: Existing

    /// What iOS currently holds, filtered to this app's reminders.
    ///
    /// A failure to read is not a failure to reconcile: an empty list means the
    /// diff concludes everything is missing and schedules it, and stable
    /// identifiers make that a replace rather than a duplicate. Erring towards
    /// "schedule it again" is the right direction when the alternative is a
    /// user who gets no reminder.
    private func existingEntries() async throws -> [ExistingScheduleEntry] {
        var entries: [ExistingScheduleEntry] = []

        let pending = (try? await services.notifications.pendingNotifications()) ?? []
        for request in pending {
            guard let stageID = request.stageID else { continue }
            entries.append(
                ExistingScheduleEntry(
                    stageID: stageID,
                    fireDate: request.fireDate,
                    channel: .notification,
                    escalation: request.escalation,
                    revision: request.planRevision
                )
            )
        }

        let alarms = (try? await services.alarms.scheduledAlarms()) ?? []
        for alarm in alarms {
            entries.append(
                ExistingScheduleEntry(
                    stageID: ReminderStage.ID(alarm.id.rawValue),
                    fireDate: alarm.fireDate,
                    channel: .alarm,
                    escalation: .alarm,
                    revision: alarm.planRevision
                )
            )
        }

        return entries
    }

    // MARK: Applying

    private enum ScheduleResult {
        case scheduled(StageDelivery)
        case failed(StageDelivery, permanent: Bool)
    }

    private func schedule(_ entry: DesiredScheduleEntry) async -> ScheduleResult {
        var delivery = StageDelivery()
        let now = dateProvider.now

        do {
            switch entry.channel {
            case .alarm:
                _ = try await services.alarms.schedule(
                    AlarmRequest(
                        id: AlarmRequest.ID(entry.stageID.rawValue),
                        label: entry.title,
                        fireDate: entry.fireDate,
                        allowsSnooze: true,
                        relatedTaskID: entry.taskID,
                        planRevision: entry.revision
                    )
                )
            case .notification, .reminderList:
                _ = try await services.notifications.schedule(
                    NotificationRequest(
                        // The stage id *is* the request id (sections 13 and 14).
                        // Derived, not allocated, so cancelling and replacing
                        // work without a mapping table that could go stale.
                        id: NotificationRequest.ID(entry.stageID.rawValue),
                        title: entry.title,
                        body: entry.body,
                        fireDate: entry.fireDate,
                        escalation: entry.escalation,
                        requiresCompletionConfirmation: entry.requiresConfirmation,
                        relatedTaskID: entry.taskID,
                        stageID: entry.stageID,
                        planRevision: entry.revision
                    )
                )
            }
            delivery.succeeded(at: now, revision: entry.revision)
            return .scheduled(delivery)
        } catch {
            let permanent = Self.isPermanent(error)
            delivery.failed(
                at: now,
                reason: Self.reason(for: error),
                isPermanent: permanent
            )
            return .failed(delivery, permanent: permanent)
        }
    }

    private func withdraw(stageID: ReminderStage.ID) async {
        let raw = stageID.rawValue
        _ = try? await services.notifications.cancel(id: NotificationRequest.ID(raw))
        _ = try? await services.alarms.cancel(id: AlarmRequest.ID(raw))
    }

    private func persistDeliveryStates(
        _ updates: [ReminderPlan.ID: [ReminderStage.ID: StageDelivery]]
    ) async throws {
        for (planID, stages) in updates {
            guard var plan = try await repositories.reminderPlans.plan(id: planID) else { continue }
            var changed = false
            for index in plan.stages.indices {
                guard let delivery = stages[plan.stages[index].id] else { continue }
                plan.stages[index].delivery = delivery
                changed = true
            }
            // Recording *how* a stage was delivered is not a change to the plan
            // itself, so the revision deliberately does not move: bumping it
            // here would make every in-flight notification look stale the
            // instant after it was scheduled.
            if changed { try await repositories.reminderPlans.save(plan) }
        }
    }

    // MARK: Failure classification

    /// Whether retrying could ever help.
    ///
    /// Section 62: a permission the user switched off is not a transient error,
    /// and retrying it on every launch is a battery bug that also lies to the
    /// user about whether their reminder will fire. Anything else is treated as
    /// transient and bounded by the attempt count.
    static func isPermanent(_ error: any Error) -> Bool {
        guard let platform = error as? PlatformError else { return false }
        switch platform {
        case .permissionDenied, .notAvailable:
            return true
        case .notFound, .invalidRequest, .underlying:
            return false
        }
    }

    /// A short, non-identifying reason for the log and the diagnostics screen.
    ///
    /// Deliberately not the error's full description: `PlatformError.underlying`
    /// wraps whatever the OS said, and the OS is under no obligation to keep
    /// the user's reminder text out of it.
    static func reason(for error: any Error) -> String {
        guard let platform = error as? PlatformError else { return "scheduling failed" }
        switch platform {
        case .permissionDenied(let capability):
            return "\(capability.rawValue) permission denied"
        case .notAvailable(let capability, _):
            return "\(capability.rawValue) unavailable on this device"
        case .notFound:
            return "the request could not be found"
        case .invalidRequest:
            return "the request was rejected"
        case .underlying:
            return "the system refused the request"
        }
    }
}
