// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantDomain
import AssistantPlatform
import Foundation
import UserNotifications

/// UserNotifications-backed reminder delivery.
///
/// The interesting part is not scheduling — it is the *actions*. The ADHD
/// support layer depends on being able to tell a dismissal apart from a
/// confirmation, which means every reminder that carries
/// `requiresCompletionConfirmation` must be delivered with a category offering
/// explicit "Done" and "Snooze" actions, and the delegate must feed the result
/// back through `AssistantEngine.record(_:for:)`.
actor UserNotificationsService: NotificationService {
    nonisolated var platformName: String { "UserNotifications" }
    nonisolated var fidelity: PlatformFidelity { .simulated } // TODO-XCODE: .live once implemented

    func schedule(_ request: NotificationRequest) async throws -> PlatformReceipt {
        // TODO-XCODE:
        //   1. Build `UNMutableNotificationContent` from title/body.
        //   2. Map `EscalationLevel` onto `interruptionLevel`
        //      (.passive / .active / .timeSensitive / .critical).
        //      Critical alerts need a specific entitlement from Apple.
        //   3. Attach the confirmation category when
        //      `requiresCompletionConfirmation` is true, carrying
        //      `relatedTaskID` and `stageID` in `userInfo`.
        //   4. `UNCalendarNotificationTrigger` from `fireDate`.
        throw PlatformError.notAvailable(
            capability: .notifications,
            reason: "TODO-XCODE: UserNotifications not implemented"
        )
    }

    func cancel(id: NotificationRequest.ID) async throws -> PlatformReceipt {
        // TODO-XCODE: removePendingNotificationRequests(withIdentifiers:).
        throw PlatformError.notAvailable(
            capability: .notifications,
            reason: "TODO-XCODE: UserNotifications not implemented"
        )
    }

    func pendingNotifications() async throws -> [NotificationRequest] {
        // TODO-XCODE: getPendingNotificationRequests(), mapped back.
        throw PlatformError.notAvailable(
            capability: .notifications,
            reason: "TODO-XCODE: UserNotifications not implemented"
        )
    }
}

/// TODO-XCODE: `UNUserNotificationCenterDelegate` that translates the user's
/// response into an `EngagementEvent`:
///
///   - the "Done" action       → `.confirmedComplete(at:)`
///   - the "Snooze" action     → `.snoozed(until:)`
///   - `UNNotificationDismissActionIdentifier` → `.reminderDismissed(at:)`
///
/// The mapping matters: dismissal must never be reported as completion.
