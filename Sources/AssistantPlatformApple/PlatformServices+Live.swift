import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(EventKit) && canImport(UserNotifications)

/// The real platform layer, assembled.
///
/// Returned as a bundle rather than as bare `PlatformServices` because the
/// notification coordinator has a lifetime the services do not: it is the
/// delegate, it must be installed before the app finishes launching, and
/// something has to hold a strong reference to it or iOS's weak `delegate`
/// property drops it and the user's "Done" goes nowhere.
public struct AppleLivePlatform: Sendable {
    /// The five services, ready to hand to `AssistantEngine`.
    public let services: PlatformServices
    /// Install this at launch and give it a handler once the repositories are
    /// open. See `AppleNotificationCoordinator`.
    public let notifications: AppleNotificationCoordinator
}

extension PlatformServices {

    /// Every service backed by a real Apple framework.
    ///
    /// The counterpart of `PlatformServices.mock()`, and the only difference
    /// between a build that changes the user's phone and one that does not.
    /// Tests, previews and CI keep calling `mock()`; nothing about them changes
    /// because of this function's existence, which is the property the platform
    /// protocols were introduced to buy.
    ///
    /// ## Alarms are conditional, and the fallback is honest
    ///
    /// Calendar, reminders and notifications exist on every supported OS.
    /// Alarms do not: AlarmKit arrived in iOS 26 while this app supports iOS 17,
    /// so on most devices there is no alarm framework to call. Those devices get
    /// `UnavailableAlarmService`, which fails and says why — **not** a silent
    /// downgrade to a notification, which would leave someone believing they
    /// had set an alarm that will never sound.
    ///
    /// Two guards, neither redundant: `#if canImport(AlarmKit)` asks whether the
    /// framework is in the SDK, and `if #available` asks whether it is on this
    /// device. Getting either wrong produces a build that will not compile or an
    /// app that will not launch.
    public static func live() -> AppleLivePlatform {
        let eventStore = AppleEventKitStore()
        let notificationService = UserNotificationsService()
        let coordinator = AppleNotificationCoordinator()

        var queries: [PlatformCapability: ApplePermissionService.Query] = [:]
        var requests: [PlatformCapability: ApplePermissionService.Query] = [:]

        queries[.calendar] = { eventStore.calendarAuthorization().permissionStatus }
        requests[.calendar] = { await eventStore.requestCalendarAccess().permissionStatus }
        queries[.reminders] = { eventStore.reminderAuthorization().permissionStatus }
        requests[.reminders] = { await eventStore.requestReminderAccess().permissionStatus }
        queries[.notifications] = { await notificationService.authorization().permissionStatus }
        requests[.notifications] = { await notificationService.requestAuthorization().permissionStatus }

        let alarms: any AlarmService

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let alarmService = AlarmKitAlarmService()
            alarms = alarmService
            queries[.alarms] = { await alarmService.authorization().permissionStatus }
            requests[.alarms] = { await alarmService.requestAuthorization().permissionStatus }
        } else {
            alarms = UnavailableAlarmService(
                reason: "Alarms need iOS 26 or later. This iPhone can set reminders instead."
            )
        }
        #else
        alarms = UnavailableAlarmService(
            reason: "This build has no alarm support."
        )
        #endif

        // No `.alarms` entry when there is no alarm framework, which reports
        // `unsupported` — the truth, and distinct from the user having said no.
        let permissions = ApplePermissionService(queries: queries, requests: requests)

        // Registered here rather than at first use: a notification whose
        // category the system has not been told about arrives with no buttons
        // and no error, and a reminder with no Done button is a reminder that
        // can only be swiped away.
        notificationService.registerCategories()

        return AppleLivePlatform(
            services: PlatformServices(
                calendar: EventKitCalendarService(store: eventStore),
                reminders: EventKitReminderService(store: eventStore),
                notifications: notificationService,
                alarms: alarms,
                permissions: permissions
            ),
            notifications: coordinator
        )
    }
}
#endif
