import AssistantDomain
import XCTest

/// "This has to happen before that", and everything that must not be allowed to
/// mean.
final class TaskDependencyTests: XCTestCase {
    private static let reference = Date(timeIntervalSince1970: 1_780_000_000)

    private func task(
        _ title: String,
        status: TaskStatus = .notStarted,
        dependsOn: [TaskItem.ID] = []
    ) -> TaskItem {
        TaskItem(
            title: title,
            status: status,
            dependsOn: dependsOn,
            createdAt: Self.reference
        )
    }

    // MARK: Validation

    func testATaskCannotDependOnItself() {
        let solo = task("Book the flight")
        let graph = TaskDependencyGraph(tasks: [solo])

        XCTAssertThrowsError(try graph.validate(prerequisite: solo.id, dependent: solo.id)) {
            XCTAssertEqual(
                $0 as? TaskDependencyGraph.ValidationError,
                .selfDependency(solo.id)
            )
        }
    }

    func testAnUnknownTaskIsRefused() {
        let known = task("Book the flight")
        let graph = TaskDependencyGraph(tasks: [known])
        let ghost = TaskItem.ID()

        XCTAssertThrowsError(try graph.validate(prerequisite: ghost, dependent: known.id)) {
            XCTAssertEqual($0 as? TaskDependencyGraph.ValidationError, .unknownTask(ghost))
        }
    }

    func testTheSameEdgeIsNotRecordedTwice() {
        let first = task("Buy the ingredients")
        let second = task("Cook dinner", dependsOn: [first.id])
        let graph = TaskDependencyGraph(tasks: [first, second])

        XCTAssertThrowsError(try graph.validate(prerequisite: first.id, dependent: second.id)) {
            XCTAssertEqual(
                $0 as? TaskDependencyGraph.ValidationError,
                .duplicateEdge(prerequisite: first.id, dependent: second.id)
            )
        }
    }

    /// A→B and B→A are each individually reasonable. Together they are two tasks
    /// that block each other forever while the assistant insists both are
    /// waiting on the other.
    func testADirectCycleIsRefused() {
        let first = task("A")
        let second = task("B", dependsOn: [first.id])
        let graph = TaskDependencyGraph(tasks: [first, second])

        XCTAssertThrowsError(try graph.validate(prerequisite: second.id, dependent: first.id)) {
            guard case .cycle = $0 as? TaskDependencyGraph.ValidationError else {
                return XCTFail("expected a cycle, got \($0)")
            }
        }
    }

    func testALongerCycleIsRefused() {
        let a = task("A")
        let b = task("B", dependsOn: [a.id])
        let c = task("C", dependsOn: [b.id])
        let graph = TaskDependencyGraph(tasks: [a, b, c])

        // A already reaches C transitively, so C → A closes the loop.
        XCTAssertThrowsError(try graph.validate(prerequisite: c.id, dependent: a.id)) {
            guard case .cycle = $0 as? TaskDependencyGraph.ValidationError else {
                return XCTFail("expected a cycle, got \($0)")
            }
        }
    }

    func testAnOrdinaryEdgeIsAccepted() {
        let first = task("Print the forms")
        let second = task("Go to the appointment")
        let graph = TaskDependencyGraph(tasks: [first, second])

        XCTAssertNoThrow(try graph.validate(prerequisite: first.id, dependent: second.id))
    }

    // MARK: Blocking

    func testATaskWaitingOnSomethingOpenIsBlocked() {
        let prerequisite = task("Collect the documents")
        let dependent = task("Submit the application", dependsOn: [prerequisite.id])
        let graph = TaskDependencyGraph(tasks: [prerequisite, dependent])

        let reason = graph.blockedReason(for: dependent)
        XCTAssertEqual(reason?.prerequisites, [prerequisite.id])
        XCTAssertEqual(reason?.titles, ["Collect the documents"])
        XCTAssertTrue(reason?.summary.contains("Collect the documents") ?? false)
    }

    /// Completed, cancelled, skipped and expired are all *settled*. Only the
    /// first is a success, and none of them should keep the next thing waiting —
    /// "you skipped the gym" still unblocks "put the kit away".
    func testEverySettledStatusUnblocks() {
        for status in TaskStatus.allCases where status.isSettled {
            let prerequisite = task("prerequisite", status: status)
            let dependent = task("dependent", dependsOn: [prerequisite.id])
            let graph = TaskDependencyGraph(tasks: [prerequisite, dependent])

            XCTAssertFalse(
                graph.isBlocked(dependent),
                "\(status.rawValue) should not block anything"
            )
        }
    }

    func testAPrerequisiteThatNoLongerExistsDoesNotBlockForever() {
        let dependent = task("Submit the application", dependsOn: [TaskItem.ID()])
        let graph = TaskDependencyGraph(tasks: [dependent])

        // Blocking on a task that was deleted would be worse than proceeding:
        // nothing could ever unblock it.
        XCTAssertFalse(graph.isBlocked(dependent))
    }

    // MARK: Unblocking

    func testCompletingAPrerequisiteReturnsWhatItFreed() {
        var prerequisite = task("Collect the documents")
        let dependent = task("Submit the application", dependsOn: [prerequisite.id])
        prerequisite.status = .completed

        let graph = TaskDependencyGraph(tasks: [prerequisite, dependent])
        XCTAssertEqual(graph.unblocked(by: prerequisite.id).map(\.id), [dependent.id])
    }

    /// Finishing one of three prerequisites frees nothing, and saying otherwise
    /// would be telling someone to start work they still cannot do.
    func testFinishingOnlyOnePrerequisiteFreesNothing() {
        var first = task("Collect the documents")
        let second = task("Book the appointment")
        let dependent = task("Go", dependsOn: [first.id, second.id])
        first.status = .completed

        let graph = TaskDependencyGraph(tasks: [first, second, dependent])
        XCTAssertTrue(graph.unblocked(by: first.id).isEmpty)
    }

    func testAlreadySettledDependentsAreNotAnnouncedAsUnblocked() {
        var prerequisite = task("Collect the documents")
        let dependent = task("Submit", status: .completed, dependsOn: [prerequisite.id])
        prerequisite.status = .completed

        let graph = TaskDependencyGraph(tasks: [prerequisite, dependent])
        XCTAssertTrue(graph.unblocked(by: prerequisite.id).isEmpty)
    }
}
