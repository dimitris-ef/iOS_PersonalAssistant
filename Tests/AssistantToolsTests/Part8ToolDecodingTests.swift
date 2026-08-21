import AssistantDomain
import XCTest
@testable import AssistantTools

/// The recurrence, dependency and start tools at the boundary.
///
/// Everything a model proposes has to survive decoding and validation before
/// anything can authorize it, and these are the cases where "the arguments
/// parsed" is not the same as "the request makes sense".
final class Part8ToolDecodingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)

    private var decoder: ToolRequestDecoder {
        ToolRequestDecoder(dateProvider: FixedDateProvider(now: now))
    }

    private func recurrence(
        frequency: String = "daily",
        interval: Int? = nil,
        weekdays: [Int]? = nil,
        dayOfMonth: Int? = nil,
        time: String = "09:00",
        endDate: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "frequency": .string(frequency),
            "time": .string(time),
        ]
        if let interval { fields["interval"] = .number(Double(interval)) }
        if let weekdays { fields["weekdays"] = .array(weekdays.map { .number(Double($0)) }) }
        if let dayOfMonth { fields["dayOfMonth"] = .number(Double(dayOfMonth)) }
        if let endDate { fields["endDate"] = .string(endDate) }
        return .object(fields)
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    // MARK: createRoutine

    func testDecodesAWeeklyRoutine() throws {
        let request = try decoder.decode(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Put the bins out"),
                "recurrence": recurrence(frequency: "weekly", weekdays: [5], time: "20:00"),
                "recoveryWindowMinutes": .number(120),
                "recoveryAllowsNextDay": .bool(true),
            ])
        )

        guard case .createRoutine(let input) = request else {
            return XCTFail("expected a routine, got \(request)")
        }
        XCTAssertEqual(input.title, "Put the bins out")
        XCTAssertNil(input.routineID, "the model must not supply identifiers")

        let rule = try input.recurrence.resolvedRule(now: now)
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.weekdays, [5])
        XCTAssertEqual(rule.timeOfDay, TimeOfDay(hour: 20))
    }

    func testRejectsAZeroInterval() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Nonsense"),
                "recurrence": recurrence(interval: 0),
            ])
        )
    }

    func testRejectsAWeeklyRuleWithNoWeekdays() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Nonsense"),
                "recurrence": recurrence(frequency: "weekly"),
            ])
        )
    }

    func testRejectsAnImpossibleDayOfMonth() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Rent"),
                "recurrence": recurrence(frequency: "monthly", dayOfMonth: 45),
            ])
        )
    }

    func testRejectsARuleThatEndsBeforeItStarts() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Nonsense"),
                "recurrence": recurrence(endDate: iso(-TimeSpan.days(30))),
            ])
        )
    }

    /// "9am" is not a time this app will guess at: it means one thing in one
    /// locale and something else in another, and a rejection gets corrected on
    /// the next round of the loop.
    func testRejectsATimeThatIsNotATime() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Medication"),
                "recurrence": recurrence(time: "9am"),
            ])
        )
    }

    func testRejectsAFrequencyNobodyHasHeardOf() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("Medication"),
                "recurrence": recurrence(frequency: "fortnightly"),
            ])
        )
    }

    func testRejectsAnEmptyRoutineTitle() {
        assertRejected(
            name: "createRoutine",
            arguments: .object([
                "title": .string("   "),
                "recurrence": recurrence(),
            ])
        )
    }

    // MARK: Preparation steps

    func testDecodesPreparationStepsOnATask() throws {
        let request = try decoder.decode(
            name: "createTask",
            arguments: .object([
                "title": .string("Go to the appointment"),
                "estimatedMinutes": .number(30),
                "preparationSteps": .array([
                    .object([
                        "title": .string("Print the forms"),
                        "estimatedMinutes": .number(5),
                        "necessity": .string("required"),
                    ]),
                    .object([
                        "title": .string("Iron a shirt"),
                        "estimatedMinutes": .number(10),
                        "necessity": .string("optional"),
                    ]),
                ]),
            ])
        )

        guard case .createTask(let input) = request else {
            return XCTFail("expected a task, got \(request)")
        }

        let steps = try XCTUnwrap(input.preparationSteps).resolvedSteps(parent: "test")
        XCTAssertEqual(steps.map(\.title), ["Print the forms", "Iron a shirt"])
        XCTAssertEqual(steps[0].necessity, .required)
        XCTAssertEqual(steps[1].necessity, .optional)
        XCTAssertEqual(steps.map(\.sequence), [0, 1])
    }

    /// Section 57. Refused rather than clamped: a model that says a shower takes
    /// six hours has misunderstood something, and silently rewriting it leaves
    /// the user with a plan nobody agreed to.
    func testRejectsAnAbsurdStepDuration() {
        assertRejected(
            name: "createTask",
            arguments: .object([
                "title": .string("Go out"),
                "preparationSteps": .array([
                    .object([
                        "title": .string("Shower"),
                        "estimatedMinutes": .number(360),
                    ]),
                ]),
            ])
        )
    }

    func testRejectsANegativeEstimate() {
        assertRejected(
            name: "createTask",
            arguments: .object([
                "title": .string("Go out"),
                "estimatedMinutes": .number(-10),
            ])
        )
    }

    func testRejectsAnUnknownNecessity() {
        assertRejected(
            name: "createTask",
            arguments: .object([
                "title": .string("Go out"),
                "preparationSteps": .array([
                    .object([
                        "title": .string("Shower"),
                        "necessity": .string("whenever"),
                    ]),
                ]),
            ])
        )
    }

    func testStepIdentitiesAreStableForTheSameParentAndTitle() {
        let input = [PreparationStepInput(title: "Leave home", estimatedMinutes: 0)]
        XCTAssertEqual(
            input.resolvedSteps(parent: "task-1").map(\.id),
            input.resolvedSteps(parent: "task-1").map(\.id)
        )
        XCTAssertNotEqual(
            input.resolvedSteps(parent: "task-1").map(\.id),
            input.resolvedSteps(parent: "task-2").map(\.id)
        )
    }

    // MARK: addTaskDependency

    func testDecodesADependency() throws {
        let prerequisite = TaskItem.ID()
        let dependent = TaskItem.ID()

        let request = try decoder.decode(
            name: "addTaskDependency",
            arguments: .object([
                "prerequisiteTaskID": .string(prerequisite.rawValue.uuidString),
                "dependentTaskID": .string(dependent.rawValue.uuidString),
            ])
        )

        guard case .addTaskDependency(let input) = request else {
            return XCTFail("expected a dependency, got \(request)")
        }
        XCTAssertEqual(input.prerequisiteTaskID, prerequisite)
        XCTAssertEqual(input.dependentTaskID, dependent)
    }

    /// The one cycle that is decidable without loading every task, so it is
    /// caught here rather than after authorization.
    func testRejectsATaskDependingOnItself() {
        let id = TaskItem.ID().rawValue.uuidString
        assertRejected(
            name: "addTaskDependency",
            arguments: .object([
                "prerequisiteTaskID": .string(id),
                "dependentTaskID": .string(id),
            ])
        )
    }

    // MARK: startTask

    func testDecodesAStartRequest() throws {
        let id = TaskItem.ID()
        let request = try decoder.decode(
            name: "startTask",
            arguments: .object(["taskID": .string(id.rawValue.uuidString)])
        )

        guard case .startTask(let input) = request else {
            return XCTFail("expected a start, got \(request)")
        }
        XCTAssertEqual(input.taskID, id)
        XCTAssertEqual(request.kind, .startTask)
        XCTAssertFalse(request.kind.isReadOnly)
        // It changes app state, not the user's calendar or alarms.
        XCTAssertFalse(request.kind.affectsSystemState)
    }

    // MARK: The catalogue

    func testEveryToolKindStillHasASpecification() {
        for kind in ToolKind.allCases {
            let specification = ToolCatalog.specification(for: kind)
            XCTAssertEqual(specification.kind, kind)
            XCTAssertFalse(specification.summary.isEmpty, "\(kind.rawValue) has no summary")
        }
    }

    // MARK: Helpers

    private func assertRejected(
        name: String,
        arguments: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try decoder.decode(name: name, arguments: arguments),
            file: file,
            line: line
        ) { error in
            guard let error = error as? ToolDecodingError else {
                return XCTFail("expected a decoding error, got \(error)", file: file, line: line)
            }
            switch error {
            case .failedValidation, .malformedArguments:
                break
            case .unknownTool:
                XCTFail("expected a rejection, not an unknown tool", file: file, line: line)
            }
        }
    }
}
