import AssistantDomain
import AssistantPlatformApple
import Foundation
import XCTest

/// What travels in a notification's `userInfo`, and what must not.
///
/// Sections 73 to 76. `userInfo` is written to disk by the system, survives
/// backups, and outlives the app version that scheduled it. So it carries
/// routing identifiers and a version number, it is treated as untrusted input
/// on the way back, and a payload from a version this build does not understand
/// is ignored rather than guessed at.
final class NotificationPayloadRevisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// Section 54. The revision goes out with the reminder and comes back with
    /// the answer, which is what makes a stale callback recognisable.
    func testThePlanRevisionSurvivesTheRoundTrip() throws {
        let request = NotificationRequest(
            title: "Pay the electricity bill",
            body: "Still open",
            fireDate: now,
            relatedTaskID: TaskItem.ID(),
            stageID: ReminderStage.ID(),
            planRevision: 7
        )

        let decoded = try XCTUnwrap(
            AppleNotificationPayload.decode(AppleNotificationPayload(request: request).userInfo)
        )

        XCTAssertEqual(decoded.planRevision, 7)
        XCTAssertEqual(decoded.stageID, request.stageID)
        XCTAssertEqual(decoded.taskID, request.relatedTaskID)
    }

    /// A notification scheduled by a build that predates revisions carries none.
    /// Absent means "cannot prove this is stale", not "ignore it" — refusing
    /// every reminder in flight across an app update would be the worse failure.
    func testAMissingRevisionDecodesAsUnknownRatherThanZero() throws {
        var userInfo = AppleNotificationPayload(
            requestID: NotificationRequest.ID(),
            taskID: TaskItem.ID(),
            stageID: ReminderStage.ID()
        ).userInfo
        userInfo.removeValue(forKey: AppleNotificationPayloadKey.planRevision)

        let decoded = try XCTUnwrap(AppleNotificationPayload.decode(userInfo))
        XCTAssertNil(decoded.planRevision)
    }

    /// Section 76: the payload is input, not instruction. A nonsense revision is
    /// dropped rather than coerced into a number that would look authoritative.
    func testAMalformedRevisionIsDiscarded() throws {
        var userInfo = AppleNotificationPayload(
            requestID: NotificationRequest.ID(),
            taskID: TaskItem.ID()
        ).userInfo
        userInfo[AppleNotificationPayloadKey.planRevision] = "not-a-number"

        let decoded = try XCTUnwrap(AppleNotificationPayload.decode(userInfo))
        XCTAssertNil(decoded.planRevision)
    }

    /// Section 74. A payload written by a future schema is not reinterpreted.
    func testAnUnknownSchemaVersionIsRejectedOutright() {
        var userInfo = AppleNotificationPayload(
            requestID: NotificationRequest.ID(),
            taskID: TaskItem.ID()
        ).userInfo
        userInfo[AppleNotificationPayloadKey.schemaVersion] = "99"

        XCTAssertNil(AppleNotificationPayload.decode(userInfo))
    }

    /// Section 75 and Part 4 section 79. The one assertion that matters most
    /// here: nothing private is in the payload. Identifiers, a flag, a version
    /// and a revision — no titles, no task details, no memory, no credentials.
    func testThePayloadCarriesNoUserContent() {
        let request = NotificationRequest(
            title: "Collect prescription for Dad",
            body: "The pharmacy closes at six",
            fireDate: now,
            relatedTaskID: TaskItem.ID(),
            stageID: ReminderStage.ID(),
            planRevision: 3
        )

        let userInfo = AppleNotificationPayload(request: request).userInfo

        XCTAssertEqual(
            Set(userInfo.keys),
            [
                AppleNotificationPayloadKey.schemaVersion,
                AppleNotificationPayloadKey.requestID,
                AppleNotificationPayloadKey.requiresConfirmation,
                AppleNotificationPayloadKey.taskID,
                AppleNotificationPayloadKey.stageID,
                AppleNotificationPayloadKey.planRevision,
            ],
            "userInfo gained a key — check it carries no user content before allowing it"
        )
        for value in userInfo.values {
            XCTAssertFalse(value.contains("prescription"))
            XCTAssertFalse(value.contains("pharmacy"))
        }
    }

    /// Section 19 and 20. Every button routes the revision through, so the
    /// service can decline any of them if the plan has moved on. The delegate
    /// itself decides nothing — it has no repositories and cannot see the plan.
    func testEveryActionCarriesTheRevisionThrough() throws {
        let task = TaskItem.ID()
        let stage = ReminderStage.ID()
        let userInfo = AppleNotificationPayload(
            requestID: NotificationRequest.ID(),
            taskID: task,
            stageID: stage,
            planRevision: 12
        ).userInfo

        let identifiers = [
            AppleNotificationAction.complete.rawValue,
            AppleNotificationAction.snooze.rawValue,
            AppleNotificationAction.working.rawValue,
            AppleNotificationResponse.dismissActionIdentifier,
        ]

        for identifier in identifiers {
            let route = AppleNotificationRouter.route(
                AppleNotificationResponse(
                    // Sections 13 and 14: the stage id *is* the request id, so
                    // the OS identifier is derived rather than allocated.
                    systemIdentifier: AppleNotificationIdentity.systemIdentifier(
                        for: NotificationRequest.ID(stage.rawValue)
                    ),
                    actionIdentifier: identifier,
                    userInfo: userInfo
                )
            )
            guard case .outcome(_, let routedTask, let routedStage, let revision) = route else {
                return XCTFail("\(identifier) should route to an outcome")
            }
            XCTAssertEqual(routedTask, task)
            XCTAssertEqual(routedStage, stage)
            XCTAssertEqual(revision, 12, "\(identifier) dropped the revision")
        }
    }
}
