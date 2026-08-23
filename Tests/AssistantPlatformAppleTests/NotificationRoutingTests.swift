import AssistantDomain
import AssistantPlatform
import AssistantPlatformApple
import ExecutiveSupport
import XCTest

/// The one rule the product is built on, tested.
///
/// These run on any machine. There is no notification centre here, no app
/// bundle and no device — which is exactly why the routing decision was pulled
/// out of the delegate into a pure function. A rule that can only be checked by
/// tapping a button on a phone is a rule nobody checks.
final class NotificationRoutingTests: XCTestCase {
    private let taskID = TaskItem.ID()
    private let stageID = ReminderStage.ID()
    private let requestID = NotificationRequest.ID()

    // MARK: The rule

    func testDismissingAReminderIsNotCompletingTheTask() throws {
        let route = AppleNotificationRouter.route(response(action: .dismiss))

        guard case .outcome(let outcome, let task, let stage, _) = route else {
            return XCTFail("A dismissal must reach the lifecycle, not be discarded: \(route)")
        }
        XCTAssertEqual(outcome, .dismissed)
        XCTAssertNotEqual(
            outcome, .completed,
            "Swiping a reminder away has never meant the task got done"
        )
        XCTAssertEqual(task, taskID)
        XCTAssertEqual(stage, stageID)
        XCTAssertFalse(outcome.resolvesTask, "A dismissal must leave the task open")
    }

    func testTheDoneButtonCompletesTheTask() throws {
        let route = AppleNotificationRouter.route(response(action: .custom(.complete)))

        guard case .outcome(let outcome, _, _, _) = route else {
            return XCTFail("Unexpected route: \(route)")
        }
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(outcome.resolvesTask)
    }

    /// The two gestures are adjacent on the same notification and mean opposite
    /// things, which is the whole reason the confirmable category exists.
    func testDoneAndDismissProduceOppositeOutcomes() throws {
        let done = AppleNotificationRouter.route(response(action: .custom(.complete)))
        let dismissed = AppleNotificationRouter.route(response(action: .dismiss))
        XCTAssertNotEqual(done, dismissed)
    }

    func testSnoozeLetsThePlanDecideWhenLaterIs() throws {
        let route = AppleNotificationRouter.route(response(action: .custom(.snooze)))

        guard case .outcome(let outcome, _, _, _) = route else {
            return XCTFail("Unexpected route: \(route)")
        }
        // Not a hard-coded interval. The button says "Later"; how long later is
        // depends on how often this task has already been put off, which the
        // reminder plan knows and this layer does not.
        XCTAssertEqual(outcome, .snoozed(until: nil))
    }

    func testImOnItAcknowledgesWithoutClaimingCompletion() throws {
        let route = AppleNotificationRouter.route(response(action: .custom(.working)))

        guard case .outcome(let outcome, _, _, _) = route else {
            return XCTFail("Unexpected route: \(route)")
        }
        XCTAssertEqual(outcome, .acknowledged)
        XCTAssertFalse(
            outcome.resolvesTask,
            "Starting something is not finishing it — support has to continue"
        )
    }

    func testTappingTheNotificationOpensTheTaskAndRecordsNothing() throws {
        let route = AppleNotificationRouter.route(response(action: .default))

        guard case .open(let task, let stage) = route else {
            return XCTFail("Unexpected route: \(route)")
        }
        XCTAssertEqual(task, taskID)
        XCTAssertEqual(stage, stageID)
    }

    // MARK: Things that are not ours

    func testANotificationFromSomewhereElseIsIgnored() throws {
        let response = AppleNotificationResponse(
            systemIdentifier: "com.example.other.notification",
            actionIdentifier: AppleNotificationResponse.dismissActionIdentifier,
            userInfo: payload().userInfo
        )
        guard case .ignored = AppleNotificationRouter.route(response) else {
            return XCTFail("Another app's notification must not drive this app's tasks")
        }
    }

    func testAPayloadFromAnOlderSchemaIsIgnoredRatherThanGuessedAt() throws {
        var userInfo = payload().userInfo
        userInfo[AppleNotificationPayloadKey.schemaVersion] = "0"

        let response = AppleNotificationResponse(
            systemIdentifier: AppleNotificationIdentity.systemIdentifier(for: requestID),
            actionIdentifier: AppleNotificationResponse.dismissActionIdentifier,
            userInfo: userInfo
        )
        guard case .ignored = AppleNotificationRouter.route(response) else {
            return XCTFail("A payload this build does not understand must not be interpreted")
        }
    }

    func testAReminderWithNoTaskBehindItIsIgnored() throws {
        let response = AppleNotificationResponse(
            systemIdentifier: AppleNotificationIdentity.systemIdentifier(for: requestID),
            actionIdentifier: AppleNotificationResponse.dismissActionIdentifier,
            userInfo: AppleNotificationPayload(requestID: requestID).userInfo
        )
        guard case .ignored = AppleNotificationRouter.route(response) else {
            return XCTFail("There is no lifecycle to advance without a task")
        }
    }

    func testAnUnknownActionIsIgnoredRatherThanTreatedAsAnAnswer() throws {
        let response = AppleNotificationResponse(
            systemIdentifier: AppleNotificationIdentity.systemIdentifier(for: requestID),
            actionIdentifier: "assistant.action.fromAFutureVersion",
            userInfo: payload().userInfo
        )
        guard case .ignored = AppleNotificationRouter.route(response) else {
            return XCTFail("An action this build does not know must not resolve anything")
        }
    }

    // MARK: Payload

    func testThePayloadRoundTrips() throws {
        let original = payload()
        let decoded = try XCTUnwrap(AppleNotificationPayload.decode(original.userInfo))
        XCTAssertEqual(decoded, original)
    }

    /// `userInfo` is written to disk by the system and survives backups.
    func testThePayloadCarriesNothingButRouting() throws {
        let request = NotificationRequest(
            id: requestID,
            title: "Ring the dentist about the crown",
            body: "You said you would do this before Thursday",
            fireDate: Date(),
            relatedTaskID: taskID,
            stageID: stageID
        )
        let values = AppleNotificationPayload(request: request).userInfo.values.joined(separator: " ")

        XCTAssertFalse(values.contains("dentist"))
        XCTAssertFalse(values.contains("Thursday"))
        XCTAssertFalse(values.lowercased().contains("crown"))
    }

    func testAMissingConfirmationFlagAssumesAnAnswerIsWanted() throws {
        var userInfo = payload().userInfo
        userInfo.removeValue(forKey: AppleNotificationPayloadKey.requiresConfirmation)

        let decoded = try XCTUnwrap(AppleNotificationPayload.decode(userInfo))
        // The failure modes are not symmetric: assuming informational would end
        // support for the task silently.
        XCTAssertTrue(decoded.requiresConfirmation)
    }

    // MARK: Categories

    func testAReminderThatWantsAnAnswerGetsButtons() {
        let confirmable = NotificationRequest(
            title: "x", body: "y", fireDate: Date(),
            requiresCompletionConfirmation: true
        )
        let informational = NotificationRequest(
            title: "x", body: "y", fireDate: Date(),
            requiresCompletionConfirmation: false
        )

        XCTAssertEqual(AppleNotificationCategory.category(for: confirmable), .confirmable)
        XCTAssertEqual(AppleNotificationCategory.category(for: informational), .informational)
    }

    /// Escalation and confirmation are separate questions, and conflating them
    /// would leave a gentle reminder about something important with no way to
    /// answer it.
    func testCategoryDoesNotDependOnHowLoudTheReminderIs() {
        for escalation in EscalationLevel.allCases {
            let request = NotificationRequest(
                title: "x", body: "y", fireDate: Date(),
                escalation: escalation,
                requiresCompletionConfirmation: true
            )
            XCTAssertEqual(
                AppleNotificationCategory.category(for: request), .confirmable,
                "\(escalation.rawValue) should still be answerable"
            )
        }
    }

    func testEveryActionIdentifierIsDistinctAndNamespaced() {
        let identifiers = AppleNotificationAction.allCases.map(\.rawValue)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("assistant."))
            // Apple's two built-in identifiers must never collide with ours,
            // or a swipe would be read as a button press.
            XCTAssertNotEqual(identifier, AppleNotificationResponse.dismissActionIdentifier)
            XCTAssertNotEqual(identifier, AppleNotificationResponse.defaultActionIdentifier)
        }
    }

    // MARK: Fixtures

    private enum Action {
        case custom(AppleNotificationAction)
        case dismiss
        case `default`

        var identifier: String {
            switch self {
            case .custom(let action): return action.rawValue
            case .dismiss: return AppleNotificationResponse.dismissActionIdentifier
            case .default: return AppleNotificationResponse.defaultActionIdentifier
            }
        }
    }

    private func payload() -> AppleNotificationPayload {
        AppleNotificationPayload(
            requestID: requestID,
            taskID: taskID,
            stageID: stageID,
            requiresConfirmation: true
        )
    }

    private func response(action: Action) -> AppleNotificationResponse {
        AppleNotificationResponse(
            systemIdentifier: AppleNotificationIdentity.systemIdentifier(for: requestID),
            actionIdentifier: action.identifier,
            userInfo: payload().userInfo
        )
    }
}
