import Foundation

/// How often a responsibility comes round.
///
/// ## Why this is not an EventKit type
///
/// `EKRecurrenceRule` is the obvious thing to reach for and the wrong one. It
/// belongs to a framework that exists on one platform, it cannot be constructed
/// without EventKit linked, and it would make "take my medication every
/// morning" — which touches no calendar at all — depend on the user having
/// granted calendar access. Recurrence is a fact about the person's life, not
/// about Apple's calendar database. The platform adapters can map this into
/// `EKRecurrenceRule` on the way out when a rule really is going into a
/// calendar; nothing on the way in needs to know that type exists.
///
/// ## Why the maths is calendar-based
///
/// Every occurrence is computed with `Calendar` and `DateComponents`, never by
/// adding 86,400 seconds. "Every morning at 9" means nine o'clock as the clock
/// on the wall reads it, and on the two days a year the clocks change, nine
/// o'clock is not twenty-four hours after the previous nine o'clock. A daily
/// medication reminder that drifts to 8 AM every spring is a bug someone
/// notices only once it has already gone wrong.
public struct RecurrenceRule: Hashable, Codable, Sendable {
    public enum Frequency: String, Hashable, Codable, Sendable, CaseIterable {
        case daily
        case weekly
        case monthly
    }

    public var frequency: Frequency
    /// Every *n* days, weeks or months. One or more.
    public var interval: Int
    /// Which days, for a weekly rule. `Calendar`'s 1-based numbering, 1 = Sunday.
    ///
    /// Sorted on the way in so two rules describing the same days are equal and
    /// hash the same, which is what lets an occurrence identity be stable.
    public var weekdays: [Int]
    /// Which day of the month, for a monthly rule.
    public var dayOfMonth: Int?
    /// What time of day the occurrence happens.
    public var timeOfDay: TimeOfDay
    /// The first day the rule applies. Occurrences never precede it.
    public var startDate: Date
    /// The last day it applies, when the user said. Nil means indefinitely.
    public var endDate: Date?

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: [Int] = [],
        dayOfMonth: Int? = nil,
        timeOfDay: TimeOfDay,
        startDate: Date,
        endDate: Date? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays.sorted()
        self.dayOfMonth = dayOfMonth
        self.timeOfDay = timeOfDay
        self.startDate = startDate
        self.endDate = endDate
    }

    // MARK: Validation

    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        case nonPositiveInterval(Int)
        case weeklyRuleWithoutWeekdays
        case weekdayOutOfRange(Int)
        case dayOfMonthOutOfRange(Int)
        case endBeforeStart

        public var description: String {
            switch self {
            case .nonPositiveInterval(let value):
                return "recurrence interval must be at least 1, got \(value)"
            case .weeklyRuleWithoutWeekdays:
                return "a weekly recurrence needs at least one weekday"
            case .weekdayOutOfRange(let value):
                return "weekday \(value) is not between 1 (Sunday) and 7 (Saturday)"
            case .dayOfMonthOutOfRange(let value):
                return "day of month \(value) is not between 1 and 31"
            case .endBeforeStart:
                return "the recurrence ends before it starts"
            }
        }
    }

    /// Rejects rules that cannot describe a real schedule.
    ///
    /// Called at the tool boundary, so a model that proposes "every 0 days"
    /// gets a validation failure rather than a generator that never terminates.
    public func validate() throws {
        guard interval >= 1 else { throw ValidationError.nonPositiveInterval(interval) }

        if frequency == .weekly {
            guard !weekdays.isEmpty else { throw ValidationError.weeklyRuleWithoutWeekdays }
        }
        for weekday in weekdays where !(1...7).contains(weekday) {
            throw ValidationError.weekdayOutOfRange(weekday)
        }
        if let dayOfMonth, !(1...31).contains(dayOfMonth) {
            throw ValidationError.dayOfMonthOutOfRange(dayOfMonth)
        }
        if let endDate, endDate < startDate {
            throw ValidationError.endBeforeStart
        }
    }

    public var isValid: Bool {
        (try? validate()) != nil
    }

    // MARK: Occurrences

    /// The first occurrence at or after `date`.
    ///
    /// Returns nil once the rule has ended. Bounded internally: a rule whose
    /// pattern can never match — the 31st of a month in a calendar without
    /// one — gives up rather than searching forever.
    public func occurrence(onOrAfter date: Date, calendar: Calendar) -> Date? {
        guard isValid else { return nil }

        let floor = max(date, startDate)
        var day = calendar.startOfDay(for: floor)
        let limit = searchLimit

        for _ in 0..<limit {
            if let candidate = occurrenceOn(day: day, calendar: calendar),
               candidate >= floor {
                guard !hasEnded(at: candidate) else { return nil }
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            if let endDate, day > calendar.startOfDay(for: endDate).addingTimeInterval(TimeSpan.day) {
                return nil
            }
        }
        return nil
    }

    /// Every occurrence inside a window, earliest first.
    ///
    /// `limit` is not optional. Occurrence generation is the one place in this
    /// app where an unbounded loop is one bad rule away, and a caller that
    /// forgot to bound it would find out in production.
    public func occurrences(in window: TimeWindow, calendar: Calendar, limit: Int) -> [Date] {
        guard limit > 0 else { return [] }

        var results: [Date] = []
        var cursor = window.start

        while results.count < limit {
            guard let next = occurrence(onOrAfter: cursor, calendar: calendar) else { break }
            guard next <= window.end else { break }
            results.append(next)
            // Advance past this occurrence by a day rather than a second, so a
            // rule matching one moment per day cannot return it twice.
            guard
                let following = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: next)
                )
            else { break }
            cursor = following
        }
        return results
    }

    // MARK: Matching

    /// The occurrence on a given calendar day, if the rule falls on it.
    private func occurrenceOn(day: Date, calendar: Calendar) -> Date? {
        guard matches(day: day, calendar: calendar) else { return nil }
        return timeOfDay.resolved(on: day, calendar: calendar)
    }

    private func matches(day: Date, calendar: Calendar) -> Bool {
        let startDay = calendar.startOfDay(for: startDate)
        guard day >= startDay else { return false }

        switch frequency {
        case .daily:
            guard interval > 1 else { return true }
            // Whole days between, so a DST day counts as one day and not 0.96.
            let elapsed = calendar.dateComponents([.day], from: startDay, to: day).day ?? 0
            return elapsed % interval == 0

        case .weekly:
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays.contains(weekday) else { return false }
            guard interval > 1 else { return true }
            // Counted in whole weeks from the start's own week, so "every other
            // Thursday" stays on the same fortnightly rhythm rather than
            // drifting whenever a month boundary falls mid-week.
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: startDay)?.start ?? startDay
            let dayWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let weeks = calendar.dateComponents([.weekOfYear], from: startWeek, to: dayWeek).weekOfYear ?? 0
            return weeks % interval == 0

        case .monthly:
            let target = dayOfMonth ?? calendar.component(.day, from: startDay)
            guard calendar.component(.day, from: day) == target else { return false }
            guard interval > 1 else { return true }
            let months = calendar.dateComponents([.month], from: startDay, to: day).month ?? 0
            return months % interval == 0
        }
    }

    private func hasEnded(at date: Date) -> Bool {
        guard let endDate else { return false }
        return date > endDate
    }

    /// How many days forward to look before concluding the rule never matches.
    ///
    /// Generous enough for the worst legitimate case — "the 31st, every third
    /// month" can be more than a year between hits — and finite, which is the
    /// property that matters.
    private var searchLimit: Int {
        switch frequency {
        case .daily: return 366 * max(1, interval)
        case .weekly: return 7 * 54 * max(1, interval)
        case .monthly: return 366 * max(1, interval) + 62
        }
    }

    // MARK: Description

    /// A short human phrase, for a routine row and for a spoken summary.
    ///
    /// Built here rather than in a view because Siri says it too, and two
    /// renderings of the same rule drift the moment either is touched.
    public func summary(calendar: Calendar = .current) -> String {
        let time = timeOfDay.description
        switch frequency {
        case .daily:
            return interval == 1 ? "Every day at \(time)" : "Every \(interval) days at \(time)"
        case .weekly:
            let names = weekdays.compactMap { Self.weekdayName($0, calendar: calendar) }
            let days = names.isEmpty ? "week" : names.joined(separator: ", ")
            return interval == 1
                ? "Every \(days) at \(time)"
                : "Every \(interval) weeks on \(days) at \(time)"
        case .monthly:
            let day = dayOfMonth ?? calendar.component(.day, from: startDate)
            return interval == 1
                ? "Day \(day) of every month at \(time)"
                : "Day \(day) every \(interval) months at \(time)"
        }
    }

    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String? {
        let symbols = calendar.weekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return nil }
        return symbols[weekday - 1]
    }
}
