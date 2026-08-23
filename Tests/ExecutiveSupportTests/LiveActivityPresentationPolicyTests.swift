import AssistantDomain
import Foundation
import XCTest

@testable import ExecutiveSupport

/// Which tasks take over the Lock Screen, and — far more often — which do not.
///
/// Section 108. The bar is deliberately high: a Live Activity is the loudest
/// non-alarm surface iOS has, it occupies the Lock Screen and the Dynamic
/// Island continuously, and one that appears for everything trains the user to
/// dismiss it. The tests that matter most here are the negative ones.
final class LiveActivityPresentationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: What does not qualify

    /// Section 47. The single most common case in anybody's list.
    func testATrivialTaskDueNextWeekGetsNoActivity() {
        let task = makeTask(
            title: "Return the library book",
            importance: .normal,
            deadline: now.addingTimeInterval(TimeSpan.days(7))
        )

        XCTAssertNil(
            LiveActivityPresentationPolicy.default.candidate(for: task, timeline: nil, now: now)
        )
    }

    /// A normal-importance task due in an hour gets a notification, which is
    /// what notifications are for. Only something the user marked important
    /// takes the Lock Screen.
    func testANormalImportanceDeadlineGetsNoActivity() {
        let task = makeTask(
            title: "Water the plants",
            importance: .normal,
            deadline: now.addingTimeInterval(TimeSpan.minutes(45))
        )

        XCTAssertNil(
            LiveActivityPresentationPolicy.default.candidate(for: task, timeline: nil, now: now)
        )
    }

    /// The most corrosive possible failure: an activity for something the user
    /// has just told the app they finished.
    func testACompletedTaskNeverQualifiesHoweverUrgentItLooks() {
        for status in [TaskStatus.completed, .cancelled, .expired, .skipped] {
            var task = makeTask(
                title: "Dentist",
                importance: .critical,
                deadline: now.addingTimeInterval(TimeSpan.minutes(20))
            )
            task.status = status

            XCTAssertNil(
                LiveActivityPresentationPolicy.default.candidate(for: task, timeline: nil, now: now),
                "\(status) still produced a Live Activity"
            )
        }
    }

    /// Even an important task is not on the Lock Screen overnight.
    func testAnImportantTaskBeyondTheLeadTimeWaits() {
        let task = makeTask(
            title: "Dentist",
            importance: .high,
            deadline: now.addingTimeInterval(TimeSpan.hours(6))
        )

        let policy = LiveActivityPresentationPolicy(leadTime: TimeSpan.hours(2))
        XCTAssertNil(policy.candidate(for: task, timeline: nil, now: now))
    }

    /// A task with no time at all has nothing to count towards.
    func testAnUnscheduledTaskGetsNoActivity() {
        let task = makeTask(title: "Sort out the loft", importance: .high, deadline: nil)
        XCTAssertNil(
            LiveActivityPresentationPolicy.default.candidate(for: task, timeline: nil, now: now)
        )
    }

    // MARK: What does

    /// Section 47's first example, and the case the whole surface exists for.
    func testAnImportantAppointmentInsideTheLeadTimeQualifies() {
        let task = makeTask(
            title: "Dentist",
            importance: .high,
            deadline: now.addingTimeInterval(TimeSpan.minutes(70))
        )

        let candidate = LiveActivityPresentationPolicy.default.candidate(
            for: task, timeline: nil, now: now
        )
        XCTAssertEqual(candidate?.reason, .deadline)
        XCTAssertEqual(candidate?.targetDate, task.deadline)
    }

    /// A running preparation timeline beats importance entirely: the user is
    /// doing this *now*, which is the situation the surface is for.
    func testARunningPreparationTimelineQualifiesWhateverTheImportance() throws {
        let anchor = now.addingTimeInterval(TimeSpan.minutes(60))
        var task = makeTask(title: "Dentist", importance: .normal, deadline: anchor)
        task.travelDuration = TimeSpan.minutes(20)
        task.preparationSteps = [
            PreparationStep(title: "Pack documents", estimatedDuration: TimeSpan.minutes(10), sequence: 0),
            PreparationStep(title: "Find the keys", estimatedDuration: TimeSpan.minutes(5), sequence: 1),
        ]

        let timeline = try XCTUnwrap(PreparationPlanner().timeline(for: task, now: now))
        // Ask at a moment that is genuinely inside the window.
        let inside = max(timeline.startAt, now)
        let candidate = LiveActivityPresentationPolicy.default.candidate(
            for: task, timeline: timeline, now: inside
        )

        XCTAssertNotNil(candidate)
        XCTAssertTrue(candidate?.reason == .preparing || candidate?.reason == .leaving)
        XCTAssertEqual(candidate?.targetDate, timeline.leaveAt)
        XCTAssertEqual(candidate?.totalSteps, timeline.keptSteps.count)
    }

    /// Close to the leave time the phase changes, which is what section 139
    /// asks the presentation to show.
    func testThePhaseBecomesLeavingNearTheLeaveTime() throws {
        let anchor = now.addingTimeInterval(TimeSpan.minutes(60))
        var task = makeTask(title: "Dentist", importance: .high, deadline: anchor)
        task.travelDuration = TimeSpan.minutes(20)
        task.preparationSteps = [
            PreparationStep(title: "Pack documents", estimatedDuration: TimeSpan.minutes(10), sequence: 0),
        ]

        let timeline = try XCTUnwrap(PreparationPlanner().timeline(for: task, now: now))
        let justBeforeLeaving = timeline.leaveAt.addingTimeInterval(-TimeSpan.minutes(5))

        let candidate = LiveActivityPresentationPolicy.default.candidate(
            for: task, timeline: timeline, now: justBeforeLeaving
        )
        XCTAssertEqual(candidate?.reason, .leaving)
    }

    /// Section 108's third case. "Help me start", accepted — `inProgress` is
    /// only ever reached by the user saying so, which makes it the clearest
    /// signal available.
    func testAnActiveStartSessionQualifies() {
        var task = makeTask(title: "Prepare documents", importance: .normal, deadline: nil)
        task.status = .inProgress
        task.preparationSteps = [
            PreparationStep(title: "Open the folder", estimatedDuration: TimeSpan.minutes(2), sequence: 0),
        ]

        let candidate = LiveActivityPresentationPolicy.default.candidate(
            for: task, timeline: nil, now: now
        )
        XCTAssertEqual(candidate?.reason, .startSession)
        XCTAssertEqual(candidate?.nextStep?.title, "Open the folder")
    }

    /// A routine occurrence inside its window qualifies without needing to be
    /// marked important — recurring responsibilities are the ones people miss.
    func testARoutineOccurrenceInsideItsWindowQualifies() {
        var task = makeTask(
            title: "Take medication",
            importance: .normal,
            deadline: now.addingTimeInterval(TimeSpan.minutes(20))
        )
        task.routineID = Routine.ID()

        let candidate = LiveActivityPresentationPolicy.default.candidate(
            for: task, timeline: nil, now: now
        )
        XCTAssertEqual(candidate?.reason, .routineWindow)
    }

    // MARK: Bounding and ordering

    /// Section 91. Not unlimited, and the cut is by urgency rather than by
    /// whatever order the repository returned.
    func testTheNumberOfSimultaneousActivitiesIsBounded() {
        let candidates = (1...6).map { index in
            LiveActivityCandidate(
                taskID: TaskItem.ID(),
                reason: .deadline,
                targetDate: now.addingTimeInterval(TimeSpan.minutes(Double(index) * 10)),
                urgency: index * 100
            )
        }

        let chosen = LiveActivityPresentationPolicy(maximumConcurrent: 2).activities(for: candidates)
        XCTAssertEqual(chosen.count, 2)
        XCTAssertEqual(chosen.map(\.urgency), [600, 500])
    }

    /// Leaving beats preparing beats starting beats a plain deadline. The
    /// ordering is what decides which two of five things the user sees.
    func testLeavingOutranksEverythingElse() {
        let leaving = LiveActivityCandidate(taskID: TaskItem.ID(), reason: .leaving, urgency: 900)
        let preparing = LiveActivityCandidate(taskID: TaskItem.ID(), reason: .preparing, urgency: 800)
        let starting = LiveActivityCandidate(taskID: TaskItem.ID(), reason: .startSession, urgency: 700)

        let chosen = LiveActivityPresentationPolicy(maximumConcurrent: 3)
            .activities(for: [starting, preparing, leaving])
        XCTAssertEqual(chosen.map(\.reason), [.leaving, .preparing, .startSession])
    }

    /// Two candidates equal in every meaningful way still order the same way
    /// every pass — otherwise reconciliation would swap them and the user would
    /// watch their Lock Screen flicker between two things for no reason.
    func testOrderingIsStableForOtherwiseEqualCandidates() {
        let first = LiveActivityCandidate(
            taskID: TaskItem.ID(), reason: .deadline, targetDate: now, urgency: 600
        )
        let second = LiveActivityCandidate(
            taskID: TaskItem.ID(), reason: .deadline, targetDate: now, urgency: 600
        )

        let policy = LiveActivityPresentationPolicy(maximumConcurrent: 2)
        XCTAssertEqual(
            policy.activities(for: [first, second]).map(\.taskID),
            policy.activities(for: [second, first]).map(\.taskID)
        )
    }

    /// Section 53. Every activity carries the moment it stops being worth
    /// showing, so one the app forgets about still leaves by itself.
    func testEveryCandidateHasAStaleDateInTheFuture() {
        let candidate = LiveActivityCandidate(
            taskID: TaskItem.ID(),
            reason: .deadline,
            targetDate: now.addingTimeInterval(TimeSpan.minutes(30))
        )

        let stale = LiveActivityPresentationPolicy.default.staleDate(for: candidate, now: now)
        XCTAssertGreaterThan(stale, now)
        XCTAssertGreaterThan(stale, candidate.targetDate!)
    }

    /// Even one whose moment has already passed — otherwise a stale activity
    /// would be given a dismissal date in the past and never dismissed.
    func testAPastTargetStillProducesAFutureStaleDate() {
        let candidate = LiveActivityCandidate(
            taskID: TaskItem.ID(),
            reason: .startSession,
            targetDate: now.addingTimeInterval(-TimeSpan.hours(2))
        )

        XCTAssertGreaterThan(
            LiveActivityPresentationPolicy.default.staleDate(for: candidate, now: now),
            now
        )
    }

    // MARK: Fixtures

    private func makeTask(
        title: String,
        importance: Importance,
        deadline: Date?
    ) -> TaskItem {
        TaskItem(
            title: title,
            status: .notStarted,
            importance: importance,
            timing: deadline.map { .dueBy($0) } ?? .unscheduled,
            deadline: deadline,
            createdAt: now.addingTimeInterval(-TimeSpan.hours(6))
        )
    }
}
