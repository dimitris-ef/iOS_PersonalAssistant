import AssistantDomain
import Foundation

/// A receipt for something a platform service did.
///
/// `fidelity` travels with the receipt so the layer above can tell the user
/// exactly what happened, including "this was only recorded locally".
public struct PlatformReceipt: Hashable, Codable, Sendable {
    public var description: String
    public var fidelity: PlatformFidelity
    public var platformName: String
    /// Handle from the underlying store (EventKit identifier, notification
    /// request id, …) when there is one.
    public var externalIdentifier: String?

    public init(
        description: String,
        fidelity: PlatformFidelity,
        platformName: String,
        externalIdentifier: String? = nil
    ) {
        self.description = description
        self.fidelity = fidelity
        self.platformName = platformName
        self.externalIdentifier = externalIdentifier
    }
}

/// The user's calendar.
///
/// TODO-XCODE: the iOS implementation wraps EventKit (`EKEventStore`) and needs
/// the calendar usage entitlement plus a foreground authorization prompt.
public protocol CalendarService: PlatformService {
    func createEvent(_ item: CalendarItem) async throws -> (item: CalendarItem, receipt: PlatformReceipt)
    /// Replaces the stored event with `item`, matched on `item.id`.
    func updateEvent(_ item: CalendarItem) async throws -> (item: CalendarItem, receipt: PlatformReceipt)
    func deleteEvent(id: CalendarItem.ID) async throws -> PlatformReceipt
    func event(id: CalendarItem.ID) async throws -> CalendarItem?
    func events(in window: TimeWindow) async throws -> [CalendarItem]
}

/// The system reminders list.
///
/// TODO-XCODE: the iOS implementation wraps EventKit reminders.
public protocol ReminderService: PlatformService {
    func createReminder(_ item: ReminderItem) async throws -> (item: ReminderItem, receipt: PlatformReceipt)
    func completeReminder(id: ReminderItem.ID) async throws -> PlatformReceipt
    func reminders(includingCompleted: Bool) async throws -> [ReminderItem]
}

/// Local notifications.
///
/// TODO-XCODE: the iOS implementation wraps UserNotifications
/// (`UNUserNotificationCenter`), including interruption levels, categories and
/// the action buttons that let the user confirm completion rather than merely
/// dismissing.
public protocol NotificationService: PlatformService {
    func schedule(_ request: NotificationRequest) async throws -> PlatformReceipt
    func cancel(id: NotificationRequest.ID) async throws -> PlatformReceipt
    func pendingNotifications() async throws -> [NotificationRequest]
}

/// Alarms — louder and more persistent than notifications.
///
/// TODO-XCODE: the iOS implementation wraps AlarmKit. Alarms are a distinct
/// capability from notifications on iOS and cannot be emulated with one.
public protocol AlarmService: PlatformService {
    func schedule(_ request: AlarmRequest) async throws -> PlatformReceipt
    /// Replaces the stored alarm with `request`, matched on `request.id`.
    func update(_ request: AlarmRequest) async throws -> (request: AlarmRequest, receipt: PlatformReceipt)
    func cancel(id: AlarmRequest.ID) async throws -> PlatformReceipt
    func scheduledAlarms() async throws -> [AlarmRequest]
}

/// The set of OS services the assistant runs against.
///
/// Passed around as one value so wiring a new environment (mock, iOS,
/// integration test) is a single substitution.
public struct PlatformServices: Sendable {
    public let calendar: any CalendarService
    public let reminders: any ReminderService
    public let notifications: any NotificationService
    public let alarms: any AlarmService
    public let permissions: any PermissionService

    public init(
        calendar: any CalendarService,
        reminders: any ReminderService,
        notifications: any NotificationService,
        alarms: any AlarmService,
        permissions: any PermissionService
    ) {
        self.calendar = calendar
        self.reminders = reminders
        self.notifications = notifications
        self.alarms = alarms
        self.permissions = permissions
    }

    /// True only when every service is backed by a real OS framework.
    public var isFullyLive: Bool {
        [calendar.fidelity, reminders.fidelity, notifications.fidelity, alarms.fidelity]
            .allSatisfy { $0 == .live }
    }
}
