import Foundation

/// A wall-clock time of day, independent of any particular date.
public struct TimeOfDay: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }

    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Resolves this time of day on the calendar day containing `date`.
    public func resolved(on date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? date
    }
}

/// A closed span between two instants.
public struct TimeWindow: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

/// Common durations, so planning code does not sprinkle magic numbers around.
public enum TimeSpan {
    public static let minute: TimeInterval = 60
    public static let hour: TimeInterval = 3_600
    public static let day: TimeInterval = 86_400

    public static func minutes(_ count: Double) -> TimeInterval { count * minute }
    public static func hours(_ count: Double) -> TimeInterval { count * hour }
    public static func days(_ count: Double) -> TimeInterval { count * day }
}
