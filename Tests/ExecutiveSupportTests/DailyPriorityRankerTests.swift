import AssistantDomain
import ExecutiveSupport
import XCTest

/// What to do now, and the constraints on that answer that are not comparators.
final class DailyPriorityRankerTests: XCTestCase {
    private let ranker = DailyPriorityRanker()
    /// 09:00 on Wednesday 10 June 2026, London.
    ///
    /// Deliberately a morning: the "same day" term in the score would otherwise
    /// flip depending on how many of the offsets below crossed midnight, which
    /// would make these tests depend on arithmetic nobody reading them can see.
    private static let now = Date(timeIntervalSince1970: 1_781_078_400)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func task(
        _ title: String,
        status: TaskStatus = .notStarted,
        importance: Importance = .normal,
        at offsetMinutes: Double? = nil,
        dependsOn: [TaskItem.ID] = [],
        routineID: Routine.ID? = nil
    ) -> TaskItem {
        let when = offsetMinutes.map { Self.now.addingTimeInterval(TimeSpan.minutes($0)) }
        return TaskItem(
            title: title,
            status: status,
            importance: importance,
            timing: when.map { TimingPreference.fixed($0) } ?? .unscheduled,
            routineID: routineID,
            occurrenceDate: routineID != nil ? when : nil,
            dependsOn: dependsOn,
            createdAt: Self.now
        )
    }

    private func rank(_ tasks: [TaskItem]) -> [RankedTask] {
        ranker.rank(tasks, now: Self.now, calendar: calendar)
    }

    // MARK: What appears

    func testSettledTasksDoNotCompeteForAttention() {
        let open = task("Open")
        let ranked = rank([
            open,
            task("Done", status: .completed),
            task("Skipped", status: .skipped),
            task("Expired", status: .expired),
            task("Cancelled", status: .cancelled),
        ])

        XCTAssertEqual(ranked.map(\.task.id), [open.id])
    }

    func testSoonerBeatsLaterWhenNothingElseDiffers() {
        let soon = task("Soon", at: 30)
        let later = task("Later", at: 300)

        XCTAssertEqual(rank([later, soon]).first?.task.id, soon.id)
    }

    func testAMoreImportantThingOutranksALessImportantOneAtTheSameTime() {
        let ordinary = task("Ordinary", importance: .low, at: 60)
        let urgent = task("Urgent", importance: .critical, at: 60)

        XCTAssertEqual(rank([ordinary, urgent]).first?.task.id, urgent.id)
    }

    // MARK: Blocking

    func testABlockedTaskIsMarkedAndPushedDown() {
        let prerequisite = task("Collect the documents", at: 600)
        let blocked = task("Submit the application", at: 30, dependsOn: [prerequisite.id])

        let ranked = rank([prerequisite, blocked])
        let entry = try? XCTUnwrap(ranked.first { $0.task.id == blocked.id })
        XCTAssertTrue(entry?.isBlocked ?? false)
        XCTAssertNotNil(entry?.blocked)
    }

    /// Section 93: telling someone to submit the paperwork above telling them to
    /// finish it is advice they cannot follow. The penalty alone does not
    /// guarantee this — the blocked task has a deadline in half an hour and the
    /// prerequisite is ten hours away.
    func testAPrerequisiteNeverAppearsBelowTheTaskWaitingOnIt() {
        let prerequisite = task("Collect the documents", at: 600)
        let blocked = task("Submit the application", importance: .critical, at: 30,
                           dependsOn: [prerequisite.id])

        let order = rank([blocked, prerequisite]).map(\.task.id)
        let prerequisiteIndex = order.firstIndex(of: prerequisite.id)
        let blockedIndex = order.firstIndex(of: blocked.id)

        XCTAssertNotNil(prerequisiteIndex)
        XCTAssertNotNil(blockedIndex)
        XCTAssertLessThan(prerequisiteIndex ?? 0, blockedIndex ?? 0)
    }

    func testASettledPrerequisiteStopsBlocking() {
        var prerequisite = task("Collect the documents", at: 600)
        prerequisite.status = .completed
        let dependent = task("Submit the application", at: 30, dependsOn: [prerequisite.id])

        let ranked = rank([prerequisite, dependent])
        XCTAssertEqual(ranked.map(\.task.id), [dependent.id])
        XCTAssertFalse(ranked[0].isBlocked)
    }

    // MARK: Overdue

    /// A stale errand keeps nagging gently; it does not get a permanent throne
    /// above the thing happening in ten minutes.
    func testAnAncientOverdueTaskDoesNotOutrankSomethingImminent() {
        let ancient = task("Ancient", at: -60 * 24 * 30)
        let imminent = task("Imminent", at: 10)

        XCTAssertEqual(rank([ancient, imminent]).first?.task.id, imminent.id)
    }

    func testOverdueWeightIsBounded() {
        let recent = task("Yesterday", at: -60 * 24)
        let ancient = task("A month ago", at: -60 * 24 * 30)

        let ranked = rank([recent, ancient])
        let recentScore = ranked.first { $0.task.id == recent.id }?.score.overdue ?? 0
        let ancientScore = ranked.first { $0.task.id == ancient.id }?.score.overdue ?? 0

        XCTAssertGreaterThan(recentScore, 0)
        XCTAssertEqual(ancientScore, ranker.weights.overdueCeiling, accuracy: 0.001)
    }

    // MARK: Preparation and recovery

    /// The case the whole ranker turns on. The appointment is three hours away
    /// and the bill is due today, but getting ready is what to do *now*.
    func testAThingWhosePreparationShouldBeStartingWinsTheTop() {
        let bill = task("Pay the bill", importance: .high, at: 60 * 4)
        var appointment = task("Dentist", at: 60 * 3)
        appointment.travelDuration = TimeSpan.minutes(30)
        appointment.preparationDuration = TimeSpan.minutes(140)

        let ranked = rank([bill, appointment])
        XCTAssertEqual(ranked.first?.task.id, appointment.id)
        XCTAssertNotNil(ranked.first?.preparationStart)
    }

    func testAMissedTaskIsSurfacedWithoutOutrankingWhatIsHappeningNow() {
        let missed = task("Missed this morning", status: .missed, at: -180)
        let now = task("Starting in ten minutes", at: 10)

        let ranked = rank([missed, now])
        XCTAssertEqual(ranked.first?.task.id, now.id)
        XCTAssertGreaterThan(
            ranked.first { $0.task.id == missed.id }?.score.recovery ?? 0,
            0
        )
    }

    func testWorkAlreadyUnderWayIsRewarded() {
        let started = task("Started", status: .inProgress, at: 120)
        let notStarted = task("Not started", at: 120)

        XCTAssertEqual(rank([notStarted, started]).first?.task.id, started.id)
    }

    // MARK: Routines

    func testRoutineOccurrencesAreRankedAlongsideEverythingElse() {
        let occurrence = task("Take medication", at: 20, routineID: Routine.ID())
        let errand = task("Post the letter", at: 240)

        let ranked = rank([errand, occurrence])
        XCTAssertEqual(ranked.first?.task.id, occurrence.id)
        XCTAssertTrue(ranked[0].task.isRoutineOccurrence)
    }

    // MARK: Determinism

    /// Same input, same clock, same order — every time, and regardless of what
    /// order the store happened to hand them over in.
    func testTheOrderIsStableRegardlessOfInputOrder() {
        let tasks = [
            task("A", at: 30),
            task("B", at: 30),
            task("C", importance: .high, at: 90),
            task("D", at: -30),
        ]

        let forwards = rank(tasks).map(\.task.title)
        let backwards = rank(tasks.reversed()).map(\.task.title)

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, rank(tasks).map(\.task.title))
    }
}
