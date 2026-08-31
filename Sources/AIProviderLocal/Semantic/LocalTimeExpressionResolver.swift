import AssistantDomain
import Foundation

/// How a time expression was read, for the diagnostic log.
public enum LocalTimeReading: String, Hashable, Sendable {
    /// "in 10 minutes" — an offset from the clock.
    case relativeOffset
    /// "tomorrow at 3" — a day and a time.
    case dayAndTime
    /// "at 5 PM" — a time, on whichever day it next falls.
    case timeOfDay
    /// "September 5 at 18:00" — a named calendar day.
    case calendarDate
    /// "now".
    case immediate
}

/// A resolved instant and how it was arrived at.
public struct LocalResolvedTime: Hashable, Sendable {
    public var date: Date
    public var reading: LocalTimeReading

    public init(date: Date, reading: LocalTimeReading) {
        self.date = date
        self.reading = reading
    }
}

/// The outcome of reading one human time expression.
public enum LocalTimeResolution: Hashable, Sendable {
    case resolved(LocalResolvedTime)
    /// Nothing in the expression names a moment, or the moment it names has
    /// already passed. Both become a question to the user, never a guess.
    case notUnderstood(String)

    public var date: Date? {
        if case .resolved(let value) = self { return value.date }
        return nil
    }
}

/// Turns what a person said about time into an instant.
///
/// ## Why the model never does this
///
/// Section 9 and 43. On a real phone a 3B model asked to fill in a due date
/// produced one from 2023 — not because it misread the request but because
/// producing a timestamp requires knowing today's date, the device's time zone
/// and the current time, none of which a model has. It has to invent something
/// shaped like an answer, and something shaped like an answer is exactly what
/// gets executed.
///
/// So the protocol asks the model only for the words: `timeExpression` is
/// "in 10 minutes", and this type — with the app's own clock, calendar and time
/// zone injected — decides what instant that is. The model cannot be wrong
/// about a date it was never asked for.
///
/// ## Why this is not the scheduling engine
///
/// Section 11 forbids a duplicate scheduling system, and this is not one.
/// `ExecutiveSupport/ReminderScheduleResolver` decides *when the app should
/// intervene* about a task — nudge cadence, escalation, quiet hours. This
/// decides *which instant a phrase names*, which is a translation step that has
/// to happen before any of that can run. Nothing here chooses a policy; it only
/// reads a clock.
///
/// ## What it refuses to do
///
/// It has no fallback. An expression it cannot read returns `notUnderstood`
/// rather than "an hour from now", and so does one that resolves into the past.
/// A wrong time on a reminder is worse than a question, because the user finds
/// out about it by missing the thing.
public struct LocalTimeExpressionResolver: Sendable {

    public let dateProvider: DateProvider

    public init(dateProvider: DateProvider) {
        self.dateProvider = dateProvider
    }

    private var calendar: Calendar { dateProvider.calendar }

    // MARK: Resolution

    /// Resolves one expression against the injected clock.
    public func resolve(_ expression: String, from reference: Date? = nil) -> LocalTimeResolution {
        let now = reference ?? dateProvider.now
        let text = Self.normalize(expression)
        guard !text.isEmpty else { return .notUnderstood("empty expression") }

        if Self.immediatePhrases.contains(text) {
            return .resolved(LocalResolvedTime(date: now, reading: .immediate))
        }

        // A time of day is looked for first because it decides how a relative
        // phrase is read: "in 10 minutes" is an offset, but "in 2 days at 5pm"
        // is a day and a time, and adding 48 hours to the current instant would
        // quietly discard the 5pm.
        let time = Self.timeOfDay(in: text)

        if time == nil, let offset = Self.relativeOffset(in: text) {
            return .resolved(
                LocalResolvedTime(date: now.addingTimeInterval(offset), reading: .relativeOffset)
            )
        }

        let anchor = dayAnchor(in: text, now: now)
        guard anchor != nil || time != nil else {
            return .notUnderstood("no time in \"\(Self.shorten(text))\"")
        }

        let baseDay = anchor?.day ?? calendar.startOfDay(for: now)
        let explicitDay = anchor?.explicit ?? false

        let hour: Int
        let minute: Int
        if let time {
            minute = time.minute
            if time.meridiemKnown {
                hour = time.hour
            } else if explicitDay {
                // The day is already pinned, so there is no "next occurrence"
                // to pick from: read a bare hour the way people speak. "Tomorrow
                // at 3" is the afternoon.
                hour = Self.preferredHour(time.hour)
            } else if let resolved = Self.hourNextOccurring(
                time.hour, minute: minute, on: baseDay, after: now, calendar: calendar
            ) {
                hour = resolved
            } else {
                hour = Self.preferredHour(time.hour)
            }
        } else if let defaultHour = anchor?.defaultHour {
            hour = defaultHour
            minute = 0
        } else {
            // A day with no time at all. Section 13: the app owns the default,
            // deterministically, and the model is never asked to invent one.
            hour = Self.defaultHourForAWholeDay
            minute = 0
        }

        guard var resolved = compose(day: baseDay, hour: hour, minute: minute) else {
            return .notUnderstood("unrepresentable time")
        }

        if resolved <= now {
            guard !explicitDay else {
                // "at 9" on a day the user named, and it has gone. Rolling it
                // forward would be the app inventing a day; the resolver asks
                // instead (section 106).
                return .notUnderstood("that time has already passed")
            }
            guard
                let nextDay = calendar.date(byAdding: .day, value: 1, to: baseDay),
                let rolled = compose(
                    day: nextDay,
                    hour: time.map { $0.meridiemKnown ? $0.hour : Self.preferredHour($0.hour) }
                        ?? hour,
                    minute: minute
                )
            else {
                return .notUnderstood("unrepresentable time")
            }
            resolved = rolled
        }

        let reading: LocalTimeReading
        if anchor?.isCalendarDate == true {
            reading = .calendarDate
        } else if anchor != nil {
            reading = .dayAndTime
        } else {
            reading = .timeOfDay
        }
        return .resolved(LocalResolvedTime(date: resolved, reading: reading))
    }

    /// Reads a duration — "for an hour", "30 minutes".
    ///
    /// Returns nil rather than a default, for the same reason as above: an
    /// event whose length nobody stated has no length, and the app's own
    /// default is applied downstream where it can be seen.
    public func resolveDuration(_ expression: String) -> TimeInterval? {
        let text = Self.normalize(expression)
        guard !text.isEmpty else { return nil }
        guard let total = Self.totalInterval(in: text), total > 0 else { return nil }
        return total
    }

    private func compose(day: Date, hour: Int, minute: Int) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let exact = calendar.date(from: components) { return exact }
        // A time that does not exist on this day — the hour a DST jump skips.
        // Fall back to the start of the day plus the offset, which lands on the
        // next real instant rather than failing the whole request.
        return calendar.startOfDay(for: day)
            .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    // MARK: Day anchor

    struct DayAnchor {
        var day: Date
        /// Whether the user named the day, as opposed to it being inferred.
        var explicit: Bool
        /// The hour implied by a phrase such as "tonight".
        var defaultHour: Int?
        var isCalendarDate: Bool = false
    }

    /// The default for "tomorrow" with no time attached.
    static let defaultHourForAWholeDay = 9

    func dayAnchor(in text: String, now: Date) -> DayAnchor? {
        let today = calendar.startOfDay(for: now)

        if let named = Self.calendarDate(in: text, now: now, calendar: calendar) {
            return DayAnchor(
                day: named, explicit: true,
                defaultHour: Self.partOfDayHour(in: text), isCalendarDate: true
            )
        }

        if let offsetDays = Self.relativeDayOffset(in: text),
            let day = calendar.date(byAdding: .day, value: offsetDays, to: today) {
            return DayAnchor(
                day: day, explicit: true, defaultHour: Self.partOfDayHour(in: text)
            )
        }

        if text.contains("day after tomorrow"),
            let day = calendar.date(byAdding: .day, value: 2, to: today) {
            return DayAnchor(
                day: day, explicit: true, defaultHour: Self.partOfDayHour(in: text)
            )
        }
        if text.contains("tomorrow"), let day = calendar.date(byAdding: .day, value: 1, to: today) {
            return DayAnchor(
                day: day, explicit: true, defaultHour: Self.partOfDayHour(in: text)
            )
        }
        if text.contains("tonight") || text.contains("this evening") {
            return DayAnchor(day: today, explicit: true, defaultHour: 20)
        }
        if text.contains("today") {
            return DayAnchor(
                day: today, explicit: true, defaultHour: Self.partOfDayHour(in: text)
            )
        }
        if text.contains("next week"), let day = calendar.date(byAdding: .day, value: 7, to: today) {
            return DayAnchor(day: day, explicit: true, defaultHour: Self.partOfDayHour(in: text))
        }
        if let weekday = Self.weekday(in: text) {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = 0
            components.minute = 0
            components.second = 0
            if let next = calendar.nextDate(
                after: now, matching: components, matchingPolicy: .nextTime, direction: .forward
            ) {
                return DayAnchor(
                    day: calendar.startOfDay(for: next), explicit: true,
                    defaultHour: Self.partOfDayHour(in: text)
                )
            }
        }
        if let hour = Self.partOfDayHour(in: text) {
            // "in the morning" with no day. Implicit, so it may roll forward.
            return DayAnchor(day: today, explicit: false, defaultHour: hour)
        }
        return nil
    }

    // MARK: Text

    static let immediatePhrases: Set<String> = ["now", "right now", "immediately", "asap"]

    /// Phrases rewritten before parsing, so the number-and-unit reader below
    /// stays a single simple rule instead of growing a special case each time
    /// somebody says "half".
    static let phraseSubstitutions: [(String, String)] = [
        ("an hour and a half", "90 minutes"),
        ("one hour and a half", "90 minutes"),
        ("hour and a half", "90 minutes"),
        ("quarter of an hour", "15 minutes"),
        ("quarter hour", "15 minutes"),
        ("half an hour", "30 minutes"),
        ("half hour", "30 minutes"),
        ("a couple of hours", "2 hours"),
        ("a couple hours", "2 hours"),
        ("a couple of minutes", "2 minutes"),
        ("a couple minutes", "2 minutes"),
        ("a few minutes", "5 minutes"),
        ("o clock", ""),
    ]

    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "[,.;!?\"']", with: " ", options: .regularExpression)
        // "p.m." and "o'clock" survive that strip as "p m" and "o clock". The
        // word boundaries matter: a plain `"a m" -> "am"` would turn "a meeting"
        // into "ameeting".
        text = text.replacingOccurrences(
            of: "\\b([ap])\\s+m\\b", with: "$1m", options: .regularExpression
        )
        for (phrase, replacement) in phraseSubstitutions {
            text = text.replacingOccurrences(of: phrase, with: replacement)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func shorten(_ text: String) -> String {
        text.count <= 40 ? text : String(text.prefix(40)) + "…"
    }

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "fortyfive": 45, "sixty": 60, "ninety": 90,
    ]

    static let unitSeconds: [String: TimeInterval] = [
        "second": 1, "sec": 1, "minute": 60, "min": 60,
        "hour": 3600, "hr": 3600, "day": 86400, "week": 604_800,
    ]

    static let quantityPattern =
        "(\\d+|[a-z]+(?:-[a-z]+)?)\\s+(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\\b"

    /// Every number-and-unit pair in the text, summed.
    ///
    /// Summed rather than first-match-wins so "1 hour 30 minutes" is one
    /// duration and not one hour.
    static func totalInterval(in text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: quantityPattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var total: TimeInterval = 0
        var matched = false

        for match in regex.matches(in: text, range: range) {
            guard
                let numberRange = Range(match.range(at: 1), in: text),
                let unitRange = Range(match.range(at: 2), in: text)
            else { continue }
            let numberText = String(text[numberRange])
            guard let value = Int(numberText) ?? numberWords[numberText] else { continue }

            var unit = String(text[unitRange])
            if unit.hasSuffix("s") { unit.removeLast() }
            guard let seconds = unitSeconds[unit] else { continue }

            total += TimeInterval(value) * seconds
            matched = true
        }
        return matched ? total : nil
    }

    /// An offset from now — only when the sentence actually says "in"/"after".
    ///
    /// Without that guard "a 30 minute meeting tomorrow" would be read as half
    /// an hour from now.
    static func relativeOffset(in text: String) -> TimeInterval? {
        guard text.range(of: "\\b(in|after|within)\\b", options: .regularExpression) != nil
        else { return nil }
        return totalInterval(in: text)
    }

    /// "in 2 days" as a day count, for expressions that also carry a time.
    static func relativeDayOffset(in text: String) -> Int? {
        let pattern = "\\b(?:in|after)\\s+(\\d+|[a-z]+)\\s+(days?|weeks?)\\b"
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let numberRange = Range(match.range(at: 1), in: text),
            let unitRange = Range(match.range(at: 2), in: text)
        else { return nil }

        let numberText = String(text[numberRange])
        guard let value = Int(numberText) ?? numberWords[numberText] else { return nil }
        return String(text[unitRange]).hasPrefix("week") ? value * 7 : value
    }

    static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    static func weekday(in text: String) -> Int? {
        for (name, number) in weekdayNumbers.sorted(by: { $0.key < $1.key })
        where text.contains(name) {
            return number
        }
        return nil
    }

    static let partsOfDay: [(String, Int)] = [
        ("morning", 9), ("afternoon", 14), ("evening", 19), ("night", 20),
    ]

    static func partOfDayHour(in text: String) -> Int? {
        partsOfDay.first { text.contains($0.0) }?.1
    }

    static let monthNumbers: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    static let monthAlternation: String =
        monthNumbers.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    /// "September 5", "5 September", "5th of September".
    static func calendarDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        let patterns = [
            ("\\b(\(monthAlternation))\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b(?!:)", 1, 2),
            ("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(\(monthAlternation))\\b", 2, 1),
        ]
        for (pattern, monthGroup, dayGroup) in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
                ),
                let monthRange = Range(match.range(at: monthGroup), in: text),
                let dayRange = Range(match.range(at: dayGroup), in: text),
                let month = monthNumbers[String(text[monthRange])],
                let day = Int(String(text[dayRange])),
                (1...31).contains(day)
            else { continue }

            var components = calendar.dateComponents([.year], from: now)
            components.month = month
            components.day = day
            components.hour = 0
            components.minute = 0
            components.second = 0
            guard var date = calendar.date(from: components) else { continue }
            // A bare "September 5" said in October means next year, not a date
            // seven weeks gone.
            if date < calendar.startOfDay(for: now),
                let nextYear = calendar.date(byAdding: .year, value: 1, to: date) {
                date = nextYear
            }
            return date
        }
        return nil
    }

    // MARK: Time of day

    struct TimeSpec {
        var hour: Int
        var minute: Int
        /// Whether the expression settled am versus pm on its own.
        var meridiemKnown: Bool
    }

    static func timeOfDay(in text: String) -> TimeSpec? {
        if text.contains("noon") || text.contains("midday") {
            return TimeSpec(hour: 12, minute: 0, meridiemKnown: true)
        }
        if text.contains("midnight") {
            return TimeSpec(hour: 0, minute: 0, meridiemKnown: true)
        }

        // "5 PM", "5:30pm", "5 p.m."
        if let match = firstMatch(
            "\\b(\\d{1,2})(?::(\\d{2}))?\\s*([ap])\\.?m\\.?\\b", in: text
        ) {
            let hour12 = Int(match[1] ?? "") ?? 0
            let minute = Int(match[2] ?? "") ?? 0
            let isPM = (match[3] ?? "") == "p"
            guard (1...12).contains(hour12), (0...59).contains(minute) else { return nil }
            let hour = isPM ? (hour12 == 12 ? 12 : hour12 + 12) : (hour12 == 12 ? 0 : hour12)
            return TimeSpec(hour: hour, minute: minute, meridiemKnown: true)
        }

        // "18:00" — a 24-hour clock leaves nothing to decide.
        if let match = firstMatch("\\b(\\d{1,2}):(\\d{2})\\b", in: text) {
            let hour = Int(match[1] ?? "") ?? -1
            let minute = Int(match[2] ?? "") ?? -1
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return TimeSpec(hour: hour, minute: minute, meridiemKnown: true)
        }

        // "at 3" — a bare hour, and the one case where am/pm is still open.
        if let match = firstMatch(
            "\\b(?:at|by|around)\\s+(\\d{1,2})\\b(?!\\s*(?:st|nd|rd|th|:|\\d))", in: text
        ) {
            let hour = Int(match[1] ?? "") ?? -1
            guard (0...23).contains(hour) else { return nil }
            return TimeSpec(hour: hour, minute: 0, meridiemKnown: hour >= 13)
        }

        return nil
    }

    /// How a bare hour is read when there is nothing else to go on.
    ///
    /// One to seven means the afternoon or evening: nobody says "at 3" and
    /// means three in the morning. Eight to twelve are left alone.
    static func preferredHour(_ hour: Int) -> Int {
        (1...7).contains(hour) ? hour + 12 : hour
    }

    /// For a bare hour on today: whichever of `h` and `h + 12` comes next.
    static func hourNextOccurring(
        _ hour: Int, minute: Int, on day: Date, after now: Date, calendar: Calendar
    ) -> Int? {
        guard hour < 12 else { return hour }
        let candidates = hour == 0 ? [0, 12] : [hour, hour + 12]
        for candidate in candidates {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = candidate
            components.minute = minute
            components.second = 0
            if let date = calendar.date(from: components), date > now { return candidate }
        }
        return nil
    }

    /// The capture groups of the first match, by index. Groups that did not
    /// participate are simply absent.
    private static func firstMatch(_ pattern: String, in text: String) -> [Int: String]? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
            )
        else { return nil }

        var groups: [Int: String] = [:]
        for index in 0..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups[index] = String(text[range])
            }
        }
        return groups
    }
}
