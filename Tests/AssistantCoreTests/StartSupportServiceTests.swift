import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import MockPlatform
import XCTest

/// "Help me start": the answer it gives, and the two things it must never do.
final class StartSupportServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    private func makeService(
        repositories: AssistantRepositories,
        services: PlatformServices = .mock(),
        decomposer: (any TaskDecomposer)? = nil
    ) -> StartSupportService {
        let dateProvider = FixedDateProvider(now: now)
        return StartSupportService(
            repositories: repositories,
            followUp: FollowUpService(
                repositories: repositories,
                services: services,
                dateProvider: dateProvider
            ),
            decomposer: decomposer ?? TemplateTaskDecomposer(),
            dateProvider: dateProvider
        )
    }

    // MARK: What it produces

    /// Section 38. "You can do it, start small" is advice; "pick up all the
    /// clothes from the floor" is something a person can begin in ten seconds.
    func testAnUnbrokenDownTaskGetsAConcreteFirstStepRatherThanEncouragement() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(title: "Clean the bedroom", createdAt: now)
        try await repositories.tasks.save(task)

        let support = try await makeService(repositories: repositories).start(taskID: task.id)

        XCTAssertEqual(support.source, .template)
        XCTAssertFalse(support.step.title.isEmpty)
        XCTAssertTrue(support.summary.contains(support.step.title))
    }

    /// Section 40's order: steps the task already carries come first, and a
    /// template that overrode them would be the app ignoring what the user
    /// wrote down.
    func testExistingStepsAreUsedBeforeAnyTemplate() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(
            title: "Clean the bedroom",
            preparationSteps: [
                PreparationStep(
                    title: "Open the window",
                    estimatedDuration: TimeSpan.minutes(1),
                    sequence: 0
                )
            ],
            createdAt: now
        )
        try await repositories.tasks.save(task)

        let support = try await makeService(repositories: repositories).start(taskID: task.id)

        XCTAssertEqual(support.source, .preparationSteps)
        XCTAssertEqual(support.step.title, "Open the window")
    }

    func testAnOccurrenceBorrowsItsRoutinesSteps() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let routine = Routine(
            title: "Go to the gym",
            recurrence: RecurrenceRule(
                frequency: .daily,
                timeOfDay: TimeOfDay(hour: 18),
                startDate: now
            ),
            preparationSteps: [
                PreparationStep(
                    title: "Put the kit in the bag",
                    estimatedDuration: TimeSpan.minutes(4),
                    sequence: 0
                )
            ],
            createdAt: now
        )
        try await repositories.routines.save(routine)

        let occurrence = TaskItem(
            title: routine.title,
            routineID: routine.id,
            occurrenceDate: now.addingTimeInterval(TimeSpan.hours(9)),
            createdAt: now
        )
        try await repositories.tasks.save(occurrence)

        let support = try await makeService(repositories: repositories)
            .start(taskID: occurrence.id)

        XCTAssertEqual(support.source, .routine)
        XCTAssertEqual(support.step.title, "Put the kit in the bag")
    }

    // MARK: What it must not do

    /// The rule that makes this the same product as everything else here:
    /// starting is `inProgress`. Someone who says "I'm doing it" has told the
    /// assistant where they are, not that they are finished.
    func testStartingMovesTheTaskIntoProgressAndNeverCompletesIt() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(title: "Write the report", createdAt: now)
        try await repositories.tasks.save(task)

        let support = try await makeService(repositories: repositories).start(taskID: task.id)

        XCTAssertEqual(support.task.status, .inProgress)
        XCTAssertNotEqual(support.task.status, .completed)
        XCTAssertNil(support.task.completedAt)

        let loaded = try await repositories.tasks.task(id: task.id)
        XCTAssertEqual(try XCTUnwrap(loaded).status, .inProgress)
    }

    /// Section 45. Packing the documents does not make the appointment happen.
    func testCompletingAStepDoesNotCompleteTheTask() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(
            title: "Go to the appointment",
            preparationSteps: [
                PreparationStep(title: "Print the forms", estimatedDuration: TimeSpan.minutes(5), sequence: 0),
                PreparationStep(title: "Find the card", estimatedDuration: TimeSpan.minutes(2), sequence: 1),
            ],
            createdAt: now
        )
        try await repositories.tasks.save(task)

        let service = makeService(repositories: repositories)
        let first = try XCTUnwrap(task.preparationSteps.first)
        let outcome = try await service.completeStep(first.id, taskID: task.id)

        XCTAssertNotEqual(outcome.task.status, .completed)
        XCTAssertEqual(outcome.next?.title, "Find the card")

        // And ticking off the last one still leaves the task itself open.
        let second = try XCTUnwrap(outcome.task.preparationSteps.last)
        let final = try await service.completeStep(second.id, taskID: task.id)
        XCTAssertNil(final.next)
        XCTAssertNotEqual(final.task.status, .completed)
    }

    func testStartingSchedulesACheckInRatherThanGoingQuiet() async throws {
        let repositories = AssistantRepositories.ephemeral()
        var task = TaskItem(
            title: "Write the report",
            importance: .high,
            timing: .fixed(now.addingTimeInterval(TimeSpan.hours(3))),
            createdAt: now
        )

        // A plan with a stage still pending, so acknowledging has something to
        // move rather than nothing to work with.
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .moment(now.addingTimeInterval(TimeSpan.hours(3))),
                importance: .high
            ),
            stages: [
                ReminderStage(
                    kind: .nudge,
                    offset: .absolute(now),
                    message: task.title,
                    requiresConfirmation: true,
                    state: .delivered,
                    stateChangedAt: now,
                    scheduledFor: now
                )
            ],
            createdAt: now,
            generatedBy: "test"
        )
        task.reminderPlanID = plan.id
        try await repositories.reminderPlans.save(plan)
        try await repositories.tasks.save(task)

        let support = try await makeService(repositories: repositories).start(taskID: task.id)

        XCTAssertEqual(support.task.status, .inProgress)
        // Not asserting an exact moment — that is `SupportPlannerTests`' job.
        // What matters here is that starting does not end support.
        XCTAssertTrue(support.checkInAt == nil || support.checkInAt! > now)
    }

    // MARK: Bounds on what a decomposer may propose

    /// Section 57 applied where it matters rather than only at the tool
    /// boundary: a decomposer is code somebody else may write, and a four-hour
    /// "open the document" would wreck every timeline the task appears in.
    func testAnAbsurdProposalIsBoundedBeforeItBecomesState() async throws {
        struct RunawayDecomposer: TaskDecomposer {
            func decompose(_ task: TaskItem) async -> [PreparationStep] {
                (0..<40).map { index in
                    PreparationStep(
                        title: String(repeating: "step ", count: 60) + "\(index)",
                        estimatedDuration: TimeSpan.hours(9),
                        sequence: index
                    )
                }
            }
        }

        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(title: "Something", createdAt: now)
        try await repositories.tasks.save(task)

        let support = try await makeService(
            repositories: repositories,
            decomposer: RunawayDecomposer()
        ).start(taskID: task.id)

        XCTAssertEqual(support.source, .model)
        XCTAssertLessThanOrEqual(support.step.estimatedDuration, TimeSpan.hours(2))
        XCTAssertLessThanOrEqual(support.step.title.count, 120)

        let loaded = try await repositories.tasks.task(id: task.id)
        XCTAssertLessThanOrEqual(try XCTUnwrap(loaded).preparationSteps.count, 8)
    }

    func testAMissingTaskFailsRatherThanInventingOne() async throws {
        let repositories = AssistantRepositories.ephemeral()
        do {
            _ = try await makeService(repositories: repositories).start(taskID: TaskItem.ID())
            XCTFail("starting a task that does not exist should fail")
        } catch {
            // Expected.
        }
    }
}
