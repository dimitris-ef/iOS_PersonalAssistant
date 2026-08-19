import AssistantPlatform
import Foundation

/// Apple's three authorization vocabularies, mirrored so the translation into
/// `PermissionStatus` is a pure function.
///
/// The same trick as `AppleModelAvailabilityState` in the Apple AI provider,
/// for the same reason: a CI runner has no calendar database, no notification
/// centre and no alarm daemon, so the only way these mappings get checked is if
/// they can be evaluated without one. The framework enums are converted to
/// these at the boundary, in a handful of lines each.
public enum AppleCalendarAuthorization: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case fullAccess
    /// "Add Events Only" — iOS 17's middle answer.
    case writeOnly

    /// What this means for a calendar capability that has to read as well as
    /// write.
    ///
    /// `writeOnly` becomes `limited` rather than `granted`. The assistant's
    /// central behaviour is knowing what is already on your day before it
    /// suggests anything, and `CalendarService` declares `events(in:)` for that
    /// reason. Write-only access cannot answer it, and an app that reported
    /// `granted` and then silently returned an empty schedule would give
    /// confidently wrong advice — "you're free at three" to someone who is not.
    public var permissionStatus: PermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        }
    }
}

public enum AppleReminderAuthorization: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case fullAccess

    /// Reminders have no write-only tier — EventKit offers full access or
    /// nothing — so this mapping has no `limited` case to make.
    public var permissionStatus: PermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .granted
        }
    }
}

public enum AppleNotificationAuthorization: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    /// Delivered quietly to Notification Centre without ever having asked.
    case provisional
    /// An App Clip's temporary grant.
    case ephemeral

    /// `provisional` is `limited`, and that distinction earns its keep.
    ///
    /// A provisional notification is delivered silently, with no banner and no
    /// sound, straight to Notification Centre. For most apps that is a
    /// reasonable trial mode. For this one it is close to useless: a reminder
    /// nobody is shown is a reminder nobody acts on, which is the failure the
    /// whole follow-up ladder exists to catch. Reporting it as `granted` would
    /// make the app believe it was reminding someone who was hearing nothing.
    public var permissionStatus: PermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .granted
        case .provisional, .ephemeral: return .limited
        }
    }
}

public enum AppleAlarmAuthorization: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case denied
    case authorized

    public var permissionStatus: PermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .granted
        }
    }
}
