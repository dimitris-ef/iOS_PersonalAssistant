import AssistantPlatform
import Foundation

/// Grants everything by default; configurable for tests that need a denial.
///
/// Deliberately not a model of the iOS flow. A real prompt needs a foreground
/// app and a human, and neither exists in a test process — so this answers
/// instantly and lets a test state which answer it wants. The translation from
/// Apple's authorization vocabulary is tested separately, against values rather
/// than against alerts, in `AssistantPlatformAppleTests`. TODO-XCODE remains
/// only for the prompt itself, which needs a device.
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
