import AssistantPlatform
import Foundation

/// Grants everything by default; configurable for tests that need a denial.
///
/// The real iOS permission flow cannot be modelled here — it requires a
/// foreground prompt and the user's answer. TODO-XCODE.
public actor MockPermissionService: PermissionService {
    private var statuses: [PlatformCapability: PermissionStatus]

    public init(statuses: [PlatformCapability: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(for capability: PlatformCapability) async -> PermissionStatus {
        statuses[capability] ?? .granted
    }

    @discardableResult
    public func request(_ capability: PlatformCapability) async -> PermissionStatus {
        let status = statuses[capability] ?? .granted
        statuses[capability] = status
        return status
    }

    public func setStatus(_ status: PermissionStatus, for capability: PlatformCapability) {
        statuses[capability] = status
    }
}

extension PlatformServices {
    /// The complete mock environment, wired to one shared log.
    public static func mock(log: PlatformEventLog? = nil) -> PlatformServices {
        PlatformServices(
            calendar: MockCalendarService(log: log),
            reminders: MockReminderService(log: log),
            notifications: MockNotificationService(log: log),
            alarms: MockAlarmService(log: log),
            permissions: MockPermissionService()
        )
    }
}
