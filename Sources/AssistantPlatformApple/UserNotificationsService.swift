import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(UserNotifications)
import UserNotifications

/// Real local notifications.
///
/// The scheduling is the easy half. The half that matters is that a reminder
/// which fires can be answered with something other than a swipe, and that the
/// answer gets back into the task lifecycle — see `AppleNotificationRouter` and
/// `AppleNotificationCoordinator`.
actor UserNotificationsService: NotificationService {
    nonisolated let platformName = "UserNotifications"
    nonisolated let fidelity: PlatformFidelity = .live

    /// Resolved per call rather than stored.
    ///
    /// `UNUserNotificationCenter.current()` traps when there is no application
    /// bundle — which is exactly the situation in a unit test process. Making
    /// it a computed property means constructing this service is harmless
    /// anywhere, and only actually using it needs an app.
    private nonisolated var center: UNUserNotificationCenter { .current() }

    func schedule(_ request: NotificationRequest) async throws -> PlatformReceipt {
        // Checked before adding, because `add(_:)` does not fail when
        // notifications are off. It accepts the request, stores it, and
        // delivers nothing — so an unguarded implementation would report
        // success for a reminder that will never be seen. That is the precise
        // shape of failure this app cannot afford.
        //
        // Asking here, rather than at launch, is what makes the permission
        // contextual: the prompt appears the first time the assistant actually
        // has something to remind the user about. It is also the only place it
        // *can* be asked — reminders are scheduled by the follow-up ladder as
        // well as by tools, and that path does not go through `ToolExecutor`'s
        // permission gate.
        var status = await authorization().permissionStatus
        if status == .notDetermined {
            status = await requestAuthorization().permissionStatus
        }
        guard status.allowsAccess else {
            throw PlatformError.permissionDenied(capability: .notifications)
        }

        let delivery = AppleEscalationMapping.delivery(for: request.escalation)

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = AppleNotificationCategory.category(for: request).rawValue
        content.userInfo = AppleNotificationPayload(request: request).userInfo
        content.interruptionLevel = Self.interruptionLevel(delivery.interruptionLevel)
        if delivery.playsSound {
            content.sound = .default
        }
        // `relevanceScore` orders the notification summary. A reminder the user
        // still has to act on belongs above one that is merely informational.
        content.relevanceScore = request.requiresCompletionConfirmation ? 1.0 : 0.5

        let identifier = AppleNotificationIdentity.systemIdentifier(for: request.id)
        let notification = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: Self.trigger(for: request.fireDate)
        )

        do {
            // Adding with an identifier that already exists **replaces** the
            // existing request rather than adding a second one. That is what
            // makes snoozing safe: the follow-up service cancels and
            // reschedules against the same stage id, and even if the cancel
            // were lost the user would still end up with one reminder rather
            // than two.
            try await center.add(notification)
        } catch {
            throw PlatformError.underlying("The reminder could not be scheduled.")
        }

        var description = "Reminder set: \(request.title) — \(Self.format(request.fireDate))"
        if let note = delivery.downgradeNote {
            // Said out loud rather than swallowed. The caller asked for
            // alarm-level insistence and is getting a notification, and the
            // receipt is what the user eventually reads.
            description += " (\(note))"
        }

        ApplePlatformLog.debug("Scheduled notification [\(request.escalation.rawValue)]")
        return receipt(description, identifier: identifier)
    }

    func cancel(id: NotificationRequest.ID) async throws -> PlatformReceipt {
        let identifier = AppleNotificationIdentity.systemIdentifier(for: id)

        let pending = await center.pendingNotificationRequests()
            .contains { $0.identifier == identifier }
        let delivered = await center.deliveredNotifications()
            .contains { $0.request.identifier == identifier }

        guard pending || delivered else {
            throw PlatformError.notFound(identifier: id.description)
        }

        // Both lists, and this is not belt-and-braces. A reminder that already
        // fired is sitting on the lock screen; finishing the task has to take
        // it away too, or the user completes something and is then asked about
        // it again by a notification that outlived its own reason.
        //
        // Named identifiers only — never `removeAllPendingNotificationRequests`,
        // which would also delete notifications this feature did not schedule.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        return receipt("Reminder withdrawn", identifier: identifier)
    }

    func pendingNotifications() async throws -> [NotificationRequest] {
        let requests = await center.pendingNotificationRequests()

        return requests.compactMap { request -> NotificationRequest? in
            guard let id = AppleNotificationIdentity.requestIdentifier(from: request.identifier),
                  let payload = AppleNotificationPayload.decode(
                      Self.stringUserInfo(request.content.userInfo)
                  )
            else { return nil }

            return NotificationRequest(
                id: id,
                title: request.content.title,
                body: request.content.body,
                fireDate: Self.fireDate(of: request.trigger) ?? Date(),
                // Read back from what iOS was actually told, not from a copy of
                // the original intent. `.alarm` cannot come back out of a
                // notification because it never went in — the highest a
                // notification carries is `.insistent`, and reporting that is
                // the honest answer to "what is scheduled?".
                escalation: Self.escalation(request.content.interruptionLevel),
                requiresCompletionConfirmation: payload.requiresConfirmation,
                relatedTaskID: payload.taskID,
                stageID: payload.stageID
            )
        }
    }

    // MARK: Authorization

    func authorization() async -> AppleNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
        }
    }

    /// Asks for the permissions a reminder needs, once.
    ///
    /// Alerts, sound and badge — the three that make a reminder noticeable.
    ///
    /// Two options are deliberately not requested. `.criticalAlert` needs an
    /// entitlement Apple grants case by case and this app does not have, and
    /// asking for one you do not hold simply fails. `.provisional` would let
    /// notifications start arriving without ever showing a prompt, which sounds
    /// generous and is not: provisional notifications are delivered silently to
    /// Notification Centre, so the app would be reminding someone who sees
    /// nothing. For this product, being asked is better than being ignored.
    ///
    /// TODO-DEVICE: iOS will only put this alert on screen while the app is in
    /// the foreground. A reminder scheduled by the follow-up ladder while the
    /// app is backgrounded may therefore find the permission still
    /// undetermined and fail rather than prompt. Settings offers a deterministic
    /// path, but which of the two happens first in practice has not been seen.
    func requestAuthorization() async -> AppleNotificationAuthorization {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]

        do {
            _ = try await center.requestAuthorization(options: options)
        } catch {
            ApplePlatformLog.error("Notification authorization request failed")
        }
        return await authorization()
    }

    /// Tells iOS about the buttons, once per launch.
    ///
    /// Categories are process-wide state, not per-notification: a notification
    /// carrying a category identifier the system has not been told about is
    /// delivered with no buttons at all and no error anywhere. So this runs at
    /// launch, before anything can be scheduled.
    nonisolated func registerCategories() {
        let categories = Set(AppleNotificationCategory.allCases.map(Self.category))
        center.setNotificationCategories(categories)
    }

    private nonisolated static func category(
        _ category: AppleNotificationCategory
    ) -> UNNotificationCategory {
        let actions: [UNNotificationAction]
        switch category {
        case .confirmable:
            actions = AppleNotificationAction.allCases.map { action in
                var options: UNNotificationActionOptions = []
                if action.opensApplication { options.insert(.foreground) }
                if action.isDestructive { options.insert(.destructive) }
                return UNNotificationAction(
                    identifier: action.rawValue,
                    title: action.title,
                    options: options
                )
            }
        case .informational:
            actions = []
        }

        return UNNotificationCategory(
            identifier: category.rawValue,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    // MARK: Mapping

    private nonisolated static func interruptionLevel(
        _ level: AppleInterruptionLevel
    ) -> UNNotificationInterruptionLevel {
        switch level {
        case .passive: return .passive
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        case .critical: return .critical
        }
    }

    private nonisolated static func escalation(
        _ level: UNNotificationInterruptionLevel
    ) -> EscalationLevel {
        switch level {
        case .passive: return .gentle
        case .active: return .standard
        case .timeSensitive, .critical: return .insistent
        @unknown default: return .standard
        }
    }

    /// A calendar trigger for a future date; an immediate one for a past date.
    ///
    /// The fallback is the interesting case. `UNCalendarNotificationTrigger`
    /// with a date that has already passed never fires — silently. That would
    /// happen every time the app catches up on a reminder whose moment went by
    /// while the phone was off, which is precisely when the user most needs to
    /// hear about it. So an overdue reminder is delivered now rather than
    /// never.
    private nonisolated static func trigger(for fireDate: Date) -> UNNotificationTrigger {
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 1 else {
            return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private nonisolated static func fireDate(of trigger: UNNotificationTrigger?) -> Date? {
        switch trigger {
        case let calendar as UNCalendarNotificationTrigger:
            return calendar.nextTriggerDate()
        case let interval as UNTimeIntervalNotificationTrigger:
            return interval.nextTriggerDate()
        default:
            return nil
        }
    }

    /// `userInfo` comes back as `[AnyHashable: Any]`; the payload is all
    /// strings by construction, so anything else is not ours and is dropped
    /// rather than coerced.
    private nonisolated static func stringUserInfo(
        _ userInfo: [AnyHashable: Any]
    ) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            values[key] = value
        }
        return values
    }

    private nonisolated static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }

    private nonisolated func receipt(
        _ description: String,
        identifier: String? = nil
    ) -> PlatformReceipt {
        PlatformReceipt(
            description: description,
            fidelity: fidelity,
            platformName: platformName,
            externalIdentifier: identifier
        )
    }
}
#endif
