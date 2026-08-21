import AssistantDomain
import XCTest
@testable import AssistantTools

/// Fingerprinting and dependency ordering — the two pieces of the agent loop
/// that are pure functions and can be tested without a model anywhere near them.
final class ToolIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fingerprints

    func testTheSameRequestFingerprintsTheSameWay() {
        let a = ToolFingerprint(
            scope: "turn-1",
            request: .createTask(CreateTaskInput(title: "Call the dentist"))
        )
        let b = ToolFingerprint(
            scope: "turn-1",
            request: .createTask(CreateTaskInput(title: "Call the dentist"))
        )
        XCTAssertEqual(a, b)
    }

    func testFieldOrderCannotChangeAFingerprint() {
        // Two inputs built by naming the fields in different orders. The point
        // is that a fingerprint is taken from the *value*, so there is no
        // ordering left to differ by — which is what comparing raw JSON strings
        // would have got wrong.
        let first = CreateTaskInput(
            title: "Send the paperwork",
            details: "before Friday",
            importance: .high
        )
        var second = CreateTaskInput(title: "Send the paperwork")
        second.importance = .high
        second.details = "before Friday"

        XCTAssertEqual(
            ToolFingerprint(scope: "turn-1", request: .createTask(first)),
            ToolFingerprint(scope: "turn-1", request: .createTask(second))
        )
    }

    func testDifferentArgumentsFingerprintDifferently() {
        XCTAssertNotEqual(
            ToolFingerprint(scope: "turn-1", request: .createTask(CreateTaskInput(title: "Call the dentist"))),
            ToolFingerprint(scope: "turn-1", request: .createTask(CreateTaskInput(title: "Call the optician")))
        )
    }

    func testTheSameActionInAnotherTurnIsNotTheSameAction() {
        // The scope is what lets "remind me to call the dentist" work again
        // tomorrow. Without it, duplicate suppression would quietly refuse to
        // repeat anything the user had ever asked for.
        XCTAssertNotEqual(
            ToolFingerprint(scope: "turn-1", request: .createTask(CreateTaskInput(title: "Call the dentist"))),
            ToolFingerprint(scope: "turn-2", request: .createTask(CreateTaskInput(title: "Call the dentist")))
        )
    }

    func testAFingerprintIsStableAcrossProcesses() {
        // Not `Hasher`, which is seeded per process. This is the property that
        // makes the value usable as an identity at all, so it is asserted
        // against a literal rather than against another call.
        XCTAssertEqual(ToolFingerprint.digest(of: "abc"), "e71fa2190541574b")
    }

    // MARK: Dependency ordering

    func testAConsumerIsOrderedAfterItsProducer() {
        let taskID = TaskItem.ID()
        let followUp = DecodedToolCall(
            callID: ToolCallID(),
            request: .createFollowUp(
                CreateFollowUpInput(taskID: taskID, checkBackAt: now.addingTimeInterval(3600))
            )
        )
        let create = DecodedToolCall(
            callID: ToolCallID(),
            request: .createTask(CreateTaskInput(taskID: taskID, title: "Send the paperwork"))
        )

        let ordered = ToolDependencyResolver().resolve([followUp, create])

        XCTAssertEqual(ordered.map(\.call.request.kind), [.createTask, .createFollowUp])
        XCTAssertEqual(ordered[1].dependsOn, [create.callID])
        XCTAssertTrue(ordered[0].dependsOn.isEmpty)
    }

    func testIndependentCallsKeepTheOrderTheyWereProposedIn() {
        let calls = [
            DecodedToolCall(callID: ToolCallID(), request: .createTask(CreateTaskInput(title: "A"))),
            DecodedToolCall(callID: ToolCallID(), request: .createTask(CreateTaskInput(title: "B"))),
            DecodedToolCall(
                callID: ToolCallID(),
                request: .storeMemory(StoreMemoryInput(content: "C", kind: .fact))
            ),
        ]

        let ordered = ToolDependencyResolver().resolve(calls)

        XCTAssertEqual(ordered.map(\.call.callID), calls.map(\.callID))
    }

    func testAReferenceToSomethingNobodyCreatesIsNotADependency() {
        // A task that already exists in the store. Nothing in this round
        // produces it, so there is no edge and nothing to wait for.
        let call = DecodedToolCall(
            callID: ToolCallID(),
            request: .completeTask(CompleteTaskInput(taskID: TaskItem.ID(), confirmedByUser: true))
        )

        let ordered = ToolDependencyResolver().resolve([call])

        XCTAssertTrue(ordered[0].dependsOn.isEmpty)
    }

    func testAChainOfReferencesIsOrderedAndEveryCallSurvives() {
        // The awkward shape: an unrelated call first, then one that refers to
        // something created by a call proposed after it.
        let first = CalendarItem.ID()
        let second = CalendarItem.ID()
        let a = DecodedToolCall(
            callID: ToolCallID(),
            request: .createCalendarEvent(
                CreateCalendarEventInput(eventID: first, title: "A", start: now)
            )
        )
        let b = DecodedToolCall(
            callID: ToolCallID(),
            request: .updateCalendarEvent(UpdateCalendarEventInput(eventID: second, title: "B"))
        )
        let c = DecodedToolCall(
            callID: ToolCallID(),
            request: .createCalendarEvent(
                CreateCalendarEventInput(eventID: second, title: "C", start: now)
            )
        )

        let ordered = ToolDependencyResolver().resolve([a, b, c])

        XCTAssertEqual(ordered.count, 3, "Nothing may be dropped while reordering")
        XCTAssertEqual(Set(ordered.map(\.call.callID)), Set([a, b, c].map(\.callID)))
        let update = try? XCTUnwrap(ordered.firstIndex { $0.call.callID == b.callID })
        let create = try? XCTUnwrap(ordered.firstIndex { $0.call.callID == c.callID })
        XCTAssertLessThan(create ?? 0, update ?? 0)
    }
}
