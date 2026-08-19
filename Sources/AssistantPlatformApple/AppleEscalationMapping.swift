import AssistantDomain
import Foundation

/// iOS's four interruption levels, named here so the mapping can be tested
/// without UserNotifications and without a device.
///
/// Mirrors `UNNotificationInterruptionLevel` case for case. The duplication is
/// the same trade the Apple provider makes with availability: a small enum that
/// compiles everywhere, converted once at the framework boundary, in exchange
/// for the decision being testable at all.
public enum AppleInterruptionLevel: String, Hashable, Sendable, CaseIterable {
    case passive
    case active
    case timeSensitive
    case critical
}

/// How a reminder's insistence becomes an iOS delivery decision.
public struct AppleNotificationDelivery: Hashable, Sendable {
    public var interruptionLevel: AppleInterruptionLevel
    /// Whether a sound is attached.
    public var playsSound: Bool
    /// Set when the requested insistence could not be delivered as asked.
    ///
    /// Carried into the receipt so the user is told what actually happened,
    /// rather than the app quietly downgrading a reminder and describing it in
    /// the words that were asked for.
    public var downgradeNote: String?

    public init(
        interruptionLevel: AppleInterruptionLevel,
        playsSound: Bool,
        downgradeNote: String? = nil
    ) {
        self.interruptionLevel = interruptionLevel
        self.playsSound = playsSound
        self.downgradeNote = downgradeNote
    }
}

public enum AppleEscalationMapping {
    /// The delivery settings for one escalation level.
    ///
    /// Two things are deliberately *not* here.
    ///
    /// **`.critical` is never produced.** Critical alerts sound through the
    /// ringer switch and through Do Not Disturb, and Apple gates them behind an
    /// entitlement granted case by case for things like medical alerts. This
    /// app does not have that entitlement, and requesting the level without it
    /// does not fail loudly — it just does not happen. So the mapping stops at
    /// `.timeSensitive` and says so, instead of writing a line of code that
    /// looks like it delivers an unmissable alert and does not.
    ///
    /// **`.alarm` does not become an alarm here.** A notification cannot become
    /// one; that is what `AlarmService` is for. When a request arrives at the
    /// notification service asking for alarm-level insistence, it is delivered
    /// as the loudest notification available *and labelled as such* — the
    /// caller chose the channel, and this layer will not silently pretend the
    /// choice was honoured.
    public static func delivery(for escalation: EscalationLevel) -> AppleNotificationDelivery {
        switch escalation {
        case .gentle:
            // Delivered quietly to Notification Centre. No sound, no banner
            // interrupt — the "you will see this when you next look" tier.
            return AppleNotificationDelivery(interruptionLevel: .passive, playsSound: false)

        case .standard:
            return AppleNotificationDelivery(interruptionLevel: .active, playsSound: true)

        case .insistent:
            // Time Sensitive: breaks through Focus, and through scheduled
            // summary. This is the highest level available without a special
            // entitlement, and it is the right one for "your deadline is in
            // twenty minutes".
            return AppleNotificationDelivery(interruptionLevel: .timeSensitive, playsSound: true)

        case .alarm:
            return AppleNotificationDelivery(
                interruptionLevel: .timeSensitive,
                playsSound: true,
                downgradeNote: "delivered as a time-sensitive notification, not an alarm"
            )
        }
    }

    /// True when this escalation level asks for something a notification
    /// cannot provide.
    ///
    /// The caller uses it to decide whether the receipt needs to explain
    /// itself. It is not a licence to reroute the request — routing between
    /// channels is the domain's decision, made in `ReminderChannel`.
    public static func exceedsNotificationCapability(_ escalation: EscalationLevel) -> Bool {
        escalation == .alarm
    }
}
