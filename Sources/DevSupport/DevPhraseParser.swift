import AssistantDomain
import Foundation

/// A crude natural-language parser used only by the development harness.
///
/// **This is not the assistant's intelligence and must never ship.** Its only
/// job is to produce structured tool calls deterministically so the pipeline —
/// planning, authorization, execution, persistence — can be exercised and
/// tested on Windows before any real model is wired up. A real provider
/// replaces it entirely; nothing above it changes.
public struct DevPhraseParser: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public enum Intent: Hashable, Sendable {
        case calendarEvent(title: String, start: Date, location: String?)
        case task(title: String, timing: ParsedTiming)
        case alarm(label: String, fireDate: Date)
        case memory(content: String, kind: MemoryKind)
        case upcomingSchedule
        case unknown
    }

    public enum ParsedTiming: Hashable, Sendable {
        case fixed(Date)
        case dueBy(Date)
        case window(TimeWindow)
        case unspecified
    }

    public func parse(_ text: String, now: Date) -> Intent {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let content = capture(after: ["remember that ", "remember "], in: text) {
            return .memory(content: content, kind: memoryKind(for: content))
        }

        if lowered.contains("what's coming up")
            || lowered.contains("what is coming up")
            || lowered.contains("what do i have") {
            return .upcomingSchedule
        }

        if lowered.contains("wake me") || lowered.contains("wake up") {
            let fireDate = parseDate(in: lowered, now: now) ?? defaultMorning(after: now)
            return .alarm(label: "Wake up", fireDate: fireDate)
        }

        if let rest = capture(after: ["i need to leave for ", "i have to leave for "], in: text) {
            let title = strippedOfTimePhrases(rest)
            let start = parseDate(in: rest.lowercased(), now: now) ?? defaultMorning(after: now)
            return .task(title: "Leave for \(title)", timing: .fixed(start))
        }

        if let rest = capture(after: ["remind me to ", "i need to ", "i have to "], in: text) {
            let title = strippedOfTimePhrases(rest)
            return .task(title: title, timing: parseTiming(in: rest.lowercased(), now: now))
        }

        if let rest = capture(after: ["i have an ", "i have a ", "i have "], in: text) {
            let title = strippedOfTimePhrases(rest)
            let start = parseDate(in: rest.lowercased(), now: now)
            let location = capture(after: [" at the ", " at my "], in: rest)
            if let start {
                return .calendarEvent(title: title, start: start, location: location)
            }
            return .task(title: title, timing: .unspecified)
        }

        return .unknown
    }

    // MARK: Phrase helpers

    private func capture(after prefixes: [String], in text: String) -> String? {
        for prefix in prefixes {
            // Searched case-insensitively on `text` itself: indices taken from a
            // lowercased copy are not valid in the original string.
            guard let range = text.range(of: prefix, options: [.caseInsensitive]) else { continue }
            let rest = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    private func memoryKind(for content: String) -> MemoryKind {
        let lowered = content.lowercased()
        if lowered.contains("normally") || lowered.contains("usually") || lowered.contains("routine") {
            return .routine
        }
        if lowered.contains("prefer") || lowered.contains("don't like") || lowered.contains("hate") {
            return .preference
        }
        return .fact
    }

    /// Removes the time phrase from a captured title so events are not called
    /// "haircut next sunday at 10 pm".
    private func strippedOfTimePhrases(_ text: String) -> String {
        var result = text
        let patterns = [
            "\\bnext\\s+\(Self.weekdayAlternation)\\b",
            "\\bthis\\s+\(Self.weekdayAlternation)\\b",
            "\\bon\\s+\(Self.weekdayAlternation)\\b",
            "\\b\(Self.weekdayAlternation)\\b",
            "\\bat\\s+\\d{1,2}(:\\d{2})?\\s*(am|pm)?\\b",
            "\\bsometime\\s+this\\s+week\\b",
            "\\bthis\\s+week\\b",
            "\\btomorrow\\b",
            "\\btonight\\b",
            "\\btoday\\b",
            "\\bby\\s+\(Self.weekdayAlternation)\\b",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
    }

    // MARK: Date parsing

    private func parseTiming(in lowered: String, now: Date) -> ParsedTiming {
        if lowered.contains("this week") || lowered.contains("sometime") {
            guard let end = calendar.date(byAdding: .day, value: 7, to: now) else { return .unspecified }
            return .window(TimeWindow(start: now, end: end))
        }
        if let date = parseDate(in: lowered, now: now) {
            return lowered.contains("by ") ? .dueBy(date) : .fixed(date)
        }
        return .unspecified
    }

    func parseDate(in lowered: String, now: Date) -> Date? {
        let time = parseTimeOfDay(in: lowered)

        if lowered.contains("tomorrow") {
            guard let day = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return (time ?? TimeOfDay(hour: 9)).resolved(on: day, calendar: calendar)
        }

        if lowered.contains("tonight") {
            return (time ?? TimeOfDay(hour: 20)).resolved(on: now, calendar: calendar)
        }

        if lowered.contains("today") {
            return (time ?? TimeOfDay(hour: 18)).resolved(on: now, calendar: calendar)
        }

        if let (weekday, wantsNextWeek) = parseWeekday(in: lowered) {
            guard let day = nextOccurrence(of: weekday, after: now, skipToFollowingWeek: wantsNextWeek) else {
                return nil
            }
            return (time ?? TimeOfDay(hour: 9)).resolved(on: day, calendar: calendar)
        }

        // A bare time with no day means the next time that clock time comes round.
        if let time {
            let today = time.resolved(on: now, calendar: calendar)
            if today > now { return today }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return time.resolved(on: tomorrow, calendar: calendar)
        }

        return nil
    }

    private func parseTimeOfDay(in lowered: String) -> TimeOfDay? {
        // "at 10 pm", "at 7:30", "at 10:00 am"
        let pattern = "\\b(?:at\\s+)?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        guard let match = regex.firstMatch(in: lowered, options: [], range: range) else { return nil }

        guard let hourRange = Range(match.range(at: 1), in: lowered),
              var hour = Int(lowered[hourRange]) else { return nil }

        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: lowered) {
            minute = Int(lowered[minuteRange]) ?? 0
        }

        var meridiem: String?
        if let meridiemRange = Range(match.range(at: 3), in: lowered) {
            meridiem = String(lowered[meridiemRange])
        }

        // Without an am/pm marker a bare hour is too ambiguous to guess at, so
        // only accept it when a minute was given ("7:30").
        if meridiem == nil && match.range(at: 2).location == NSNotFound {
            return nil
        }

        if meridiem == "pm" && hour < 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        guard hour < 24 else { return nil }

        return TimeOfDay(hour: hour, minute: minute)
    }

    private func parseWeekday(in lowered: String) -> (weekday: Int, wantsNextWeek: Bool)? {
        for (index, name) in Self.weekdayNames.enumerated() {
            guard lowered.contains(name) else { continue }
            let wantsNextWeek = lowered.contains("next \(name)")
            // Calendar weekdays are 1-based starting at Sunday.
            return (index + 1, wantsNextWeek)
        }
        return nil
    }

    private func nextOccurrence(of weekday: Int, after date: Date, skipToFollowingWeek: Bool) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: date)
        var delta = weekday - currentWeekday
        if delta <= 0 { delta += 7 }
        if skipToFollowingWeek && delta < 7 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: date)
    }

    private func defaultMorning(after date: Date) -> Date {
        let day = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return TimeOfDay(hour: 7).resolved(on: day, calendar: calendar)
    }

    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    private static let weekdayAlternation = "(" + weekdayNames.joined(separator: "|") + ")"
}
