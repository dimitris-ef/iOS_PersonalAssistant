import AssistantDomain
import Foundation

/// A recurrence rule reduced to the four numbers EventKit needs.
///
/// `EKRecurrenceRule` is a class with initialisers that throw exceptions rather
/// than errors for invalid input — a zero interval terminates the process. So
/// the validation happens here, in a value type that can be tested, and the
/// EventKit file only constructs rules that have already been checked.
public struct AppleRecurrenceSpecification: Hashable, Sendable {
    public enum Frequency: String, Hashable, Sendable {
        case daily
        case weekly
        case monthly
        case yearly
    }

    public var frequency: Frequency
    /// Always at least 1. EventKit treats 0 as programmer error.
    public var interval: Int
    /// `Calendar`'s 1-based weekday numbers, empty when the frequency does not
    /// use them.
    public var weekdays: [Int]
    /// 1...31, or nil when the frequency does not use it.
    public var dayOfMonth: Int?

    public init(
        frequency: Frequency,
        interval: Int,
        weekdays: [Int] = [],
        dayOfMonth: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
    }
}

public enum AppleRecurrenceMapping {
    /// Translates a domain rule, clamping anything EventKit would reject.
    ///
    /// Clamping rather than throwing is the right call for recurrence
    /// specifically. The rule reaches here from a language model's tool
    /// arguments, and the realistic bad value is an interval of 0 meaning
    /// "every day" — refusing the whole event over it would lose the
    /// appointment, while repeating daily loses nothing the user cares about.
    ///
    /// Weekday numbers are filtered rather than clamped, because a weekday of
    /// 9 has no nearest sensible meaning. An empty result falls back to a plain
    /// weekly rule, which repeats on the start date's own weekday.
    public static func specification(for rule: RecurrenceRule) -> AppleRecurrenceSpecification {
        switch rule {
        case .daily(let interval):
            return AppleRecurrenceSpecification(
                frequency: .daily,
                interval: max(1, interval)
            )

        case .weekly(let interval, let weekdays):
            return AppleRecurrenceSpecification(
                frequency: .weekly,
                interval: max(1, interval),
                weekdays: weekdays.filter { (1...7).contains($0) }.sorted()
            )

        case .monthly(let interval, let day):
            return AppleRecurrenceSpecification(
                frequency: .monthly,
                interval: max(1, interval),
                dayOfMonth: min(31, max(1, day))
            )

        case .yearly(let interval):
            return AppleRecurrenceSpecification(
                frequency: .yearly,
                interval: max(1, interval)
            )
        }
    }
}
