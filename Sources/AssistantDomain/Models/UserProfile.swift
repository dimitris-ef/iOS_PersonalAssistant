import Foundation

/// Stable facts about the person the assistant works for.
///
/// This is deliberately separate from ``MemoryItem``: the profile holds a small
/// number of structured fields that planning code reads directly, while memory
/// holds an open-ended, growing set of remembered statements.
public struct UserProfile: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<UserProfile>

    public var id: ID
    public var displayName: String?
    public var timeZoneIdentifier: String
    public var wakeTime: TimeOfDay?
    public var sleepTime: TimeOfDay?
    /// How long this person usually needs to get ready before leaving.
    public var defaultPreparationDuration: TimeInterval
    /// Fallback travel allowance when we have no route information.
    public var defaultTravelDuration: TimeInterval
    /// Reminders are not delivered inside this window unless escalation demands it.
    public var quietHours: DayWindow?

    public init(
        id: ID = ID(),
        displayName: String? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        wakeTime: TimeOfDay? = nil,
        sleepTime: TimeOfDay? = nil,
        defaultPreparationDuration: TimeInterval = Duration.minutes(30),
        defaultTravelDuration: TimeInterval = Duration.minutes(20),
        quietHours: DayWindow? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.wakeTime = wakeTime
        self.sleepTime = sleepTime
        self.defaultPreparationDuration = defaultPreparationDuration
        self.defaultTravelDuration = defaultTravelDuration
        self.quietHours = quietHours
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
}

/// A recurring window within a day, e.g. quiet hours from 23:00 to 07:00.
public struct DayWindow: Hashable, Codable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// True when `time` falls inside the window, handling windows that wrap midnight.
    public func contains(_ time: TimeOfDay) -> Bool {
        if start <= end {
            return time >= start && time <= end
        }
        return time >= start || time <= end
    }
}
