import AssistantDomain
import Foundation

/// The names iOS knows our notifications and alarms by.
///
/// Nothing here imports a framework, and that is deliberate: identifier
/// round-tripping is the single most load-bearing piece of the notification
/// layer and it is a pure string function. Getting it wrong does not produce a
/// crash — it produces a reminder that cannot be cancelled, which is the exact
/// failure the assistant is supposed to prevent.
///
/// ## Why the identifier is derived, not stored
///
/// `UNUserNotificationCenter` keys everything by a string the app chooses.
/// The obvious design is to keep a table mapping domain ids to whatever string
/// was used, and it is the wrong one: that table is a second source of truth
/// that can be lost, can go stale after a reinstall, and has to be migrated.
///
/// Deriving the string from the domain id instead means the mapping is a
/// function, always available, and correct after a relaunch with an empty
/// cache. `FollowUpService` already uses the *stage* id as the request id, so
/// a reminder's OS-level identity follows from its place in the plan and
/// nothing else has to remember it.
public enum AppleNotificationIdentity {
    /// Reverse-DNS-ish, so an identifier found in a system log is traceable to
    /// this app and this feature rather than being an anonymous UUID.
    public static let notificationPrefix = "assistant.reminder."

    /// The string to give `UNNotificationRequest` for this domain request.
    public static func systemIdentifier(for id: NotificationRequest.ID) -> String {
        notificationPrefix + id.rawValue.uuidString
    }

    /// The domain request an OS identifier refers to, or nil.
    ///
    /// Returns nil rather than throwing for anything that is not ours. Other
    /// notifications can and do exist in the same centre — a notification
    /// service extension, a future feature, a leftover from an older build —
    /// and treating one of those as a reminder would be worse than ignoring
    /// it.
    public static func requestIdentifier(
        from systemIdentifier: String
    ) -> NotificationRequest.ID? {
        guard systemIdentifier.hasPrefix(notificationPrefix) else { return nil }
        let raw = String(systemIdentifier.dropFirst(notificationPrefix.count))
        return NotificationRequest.ID(uuidString: raw)
    }

    /// True when this identifier belongs to the assistant's reminder system.
    ///
    /// Used before any bulk removal. `removeAllPendingNotificationRequests()`
    /// would also delete notifications this app did not schedule, so every
    /// removal in this layer names identifiers explicitly and this is how the
    /// list is filtered.
    public static func isOurs(_ systemIdentifier: String) -> Bool {
        requestIdentifier(from: systemIdentifier) != nil
    }
}
