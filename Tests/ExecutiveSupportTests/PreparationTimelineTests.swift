import AssistantDomain
import ExecutiveSupport
import XCTest

/// When to start, when to leave, and what happens when that was twenty minutes
/// ago.
final class PreparationTimelineTests: XCTestCase {
    private let planner = PreparationPlanner()

    /// 16:00 on an arbitrary but fixed day. Everything else is expressed
    /// relative to it, so the tests read as clock arithmetic and depend on no
    /// real clock at all.
    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    private func minutesBeforeAnchor(_ minutes: Double) -> Date {
        Self.anchor.addingTimeInterval(-TimeSpan.minutes(minutes))
    }

    private func step(
        _ title: String,
        _ minutes: Double,
        _ necessity: StepNecessity = .required,
        sequence: Int = 0,
        isCompleted: Bool = false
    ) -> PreparationStep {
        PreparationStep(
            title: title,
            estimatedDuration: TimeSpan.minutes(minutes),
            necessity: necessity,
            sequence: sequence,
            isCompleted: isCompleted
        )
    }

    // MARK: The plan

    func testLeaveTimeIsTheAnchorLessTravelAndBuffer() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [],
            travelDuration: TimeSpan.minutes(30),
            preparationDuration: TimeSpan.minutes(45),
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )

        // 16:00 − 10m buffer − 30m travel = 15:20
        XCTAssertEqual(timeline.leaveAt, minutesBeforeAnchor(40))
        // 15:20 − 45m preparation = 14:35
        XCTAssertEqual(timeline.startAt, minutesBeforeAnchor(85))
        XCTAssertEqual(timeline.risk, .onTrack)
        XCTAssertFalse(timeline.isCompressed)
    }

    func testAnImportantCommitmentGetsAWiderBuffer() {
        let ordinary = planner.timeline(
            anchor: Self.anchor,
            steps: [],
            travelDuration: 0,
            preparationDuration: 0,
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )
        let important = planner.timeline(
            anchor: Self.anchor,
            steps: [],
            travelDuration: 0,
            preparationDuration: 0,
            importance: .critical,
            now: minutesBeforeAnchor(180)
        )

        XCTAssertLessThan(important.leaveAt, ordinary.leaveAt)
    }

    /// Steps say the same thing as a bare duration with more detail, so when
    /// there are any they win.
    func testStepsAreUsedInPreferenceToAStatedDuration() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [step("Shower", 15, sequence: 0), step("Dress", 10, sequence: 1)],
            travelDuration: 0,
            preparationDuration: TimeSpan.hours(3),
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )

        // 16:00 − 10m buffer = 15:50; − 25m of steps = 15:25.
        XCTAssertEqual(timeline.startAt, minutesBeforeAnchor(35))
    }

    func testStepsAreScheduledBackToBackInOrder() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [step("Shower", 15, sequence: 0), step("Dress", 10, sequence: 1)],
            travelDuration: 0,
            preparationDuration: nil,
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )

        XCTAssertEqual(timeline.steps.map(\.step.title), ["Shower", "Dress"])
        XCTAssertEqual(timeline.steps[0].end, timeline.steps[1].start)
        XCTAssertEqual(timeline.nextStep?.step.title, "Shower")
    }

    /// The whole point of a stable identity: replanning happens constantly, and
    /// with allocated ids every pass would append another "Leave home".
    func testReplanningReusesTheSameStepIdentities() {
        let steps = [step("Shower", 15, sequence: 0), step("Dress", 10, sequence: 1)]

        let first = planner.timeline(
            anchor: Self.anchor,
            steps: steps,
            travelDuration: nil,
            preparationDuration: nil,
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )
        // The event moved an hour later. Same steps, new times.
        let second = planner.timeline(
            anchor: Self.anchor.addingTimeInterval(TimeSpan.hour),
            steps: steps,
            travelDuration: nil,
            preparationDuration: nil,
            importance: .normal,
            now: minutesBeforeAnchor(180)
        )

        XCTAssertEqual(first.steps.map(\.id), second.steps.map(\.id))
        XCTAssertEqual(
            second.startAt.timeIntervalSince(first.startAt),
            TimeSpan.hour,
            accuracy: 1
        )
    }

    // MARK: Running late

    func testStartingLateIsReportedAsBehindRatherThanRepeatingThePlan() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [step("Shower", 15, sequence: 0)],
            travelDuration: 0,
            preparationDuration: nil,
            importance: .normal,
            // Ideal start is 15:35. It is now 15:40.
            now: minutesBeforeAnchor(20)
        )

        XCTAssertTrue(timeline.risk.isBehind)
        // And the plan now starts from now, not from a moment that has gone.
        XCTAssertEqual(timeline.startAt, minutesBeforeAnchor(20))
    }

    /// Compression's order of sacrifice: optional first, then recommended, and
    /// required steps never.
    func testCompressionDropsOptionalStepsBeforeRequiredOnes() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [
                step("Shower", 15, .required, sequence: 0),
                step("Iron a shirt", 15, .optional, sequence: 1),
                step("Make coffee", 10, .recommended, sequence: 2),
            ],
            travelDuration: 0,
            preparationDuration: nil,
            importance: .normal,
            // 20 minutes left before leaving; the full plan needs 40.
            now: minutesBeforeAnchor(30)
        )

        XCTAssertTrue(timeline.isCompressed)
        XCTAssertTrue(timeline.keptSteps.contains { $0.step.title == "Shower" })
        XCTAssertTrue(timeline.droppedSteps.contains { $0.step.title == "Iron a shirt" })
    }

    /// "You are eight minutes short" is something a person can act on. "You are
    /// late" is not.
    func testAPlanThatCannotFitSaysHowShortItIs() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [step("Shower", 30, .required, sequence: 0)],
            travelDuration: 0,
            preparationDuration: nil,
            importance: .normal,
            // Five minutes until leave time, and the one required step is 30.
            now: minutesBeforeAnchor(15)
        )

        guard case .cannotMakeIt(let shortBy) = timeline.risk else {
            return XCTFail("expected cannotMakeIt, got \(timeline.risk)")
        }
        XCTAssertGreaterThan(shortBy, 0)
        // The buffer was spent, but never below its floor.
        XCTAssertLessThanOrEqual(
            timeline.leaveAt.timeIntervalSince(Self.anchor),
            -TimeSpan.minutes(2)
        )
    }

    func testCompletedStepsAreNotCountedAgainstTheTimeThatIsLeft() {
        let timeline = planner.timeline(
            anchor: Self.anchor,
            steps: [
                step("Shower", 20, .required, sequence: 0, isCompleted: true),
                step("Dress", 10, .required, sequence: 1),
            ],
            travelDuration: 0,
            preparationDuration: nil,
            importance: .normal,
            now: minutesBeforeAnchor(25)
        )

        // 15 minutes remain before leaving and only "Dress" is still to do, so
        // this is achievable — a plan that counted the finished shower would
        // wrongly announce it is not.
        if case .cannotMakeIt = timeline.risk {
            XCTFail("a finished step should not make the rest impossible")
        }
    }

    // MARK: From a task

    func testATaskWithNoDateHasNoTimeline() {
        let task = TaskItem(title: "Sometime", createdAt: Self.anchor)
        XCTAssertNil(planner.timeline(for: task, now: Self.anchor))
    }

    func testATaskTimelineUsesItsOwnTravelAndSteps() {
        let task = TaskItem(
            title: "Dentist",
            timing: .fixed(Self.anchor),
            travelDuration: TimeSpan.minutes(20),
            preparationSteps: [step("Find the card", 5)],
            createdAt: minutesBeforeAnchor(300)
        )

        let timeline = planner.timeline(for: task, now: minutesBeforeAnchor(180))
        // 16:00 − 10m buffer − 20m travel = 15:30; − 5m step = 15:25.
        XCTAssertEqual(timeline?.leaveAt, minutesBeforeAnchor(30))
        XCTAssertEqual(timeline?.startAt, minutesBeforeAnchor(35))
    }
}
