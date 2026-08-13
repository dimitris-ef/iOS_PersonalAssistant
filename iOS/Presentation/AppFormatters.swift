import AssistantDomain
import Foundation

/// Date and duration formatting, in one place.
///
/// Formatters are expensive to build, so the shared instance is reused. All
/// output is locale-aware — nothing here assumes English or a 12-hour clock.
struct AppFormatters: RelativeTimeFormatting {
    static let shared = AppFormatters()

    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    // MARK: Absolute

    /// "10:00 PM"
    func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Sunday"
    func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    /// "Thursday, 13 August"
    func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "13 August"
    func dayAndMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide))
    }

    /// "10:00 PM – 11:00 PM"
    func timeRange(from start: Date, to end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    // MARK: Relative

    /// "Today", "Tomorrow", "Sun", or "12 Sep" further out.
    func relativeDay(_ date: Date, now: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        if days > 0 && days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return dayAndMonth(date)
    }

    /// "Today · 10:00 PM"
    func relativeDayAndTime(_ date: Date, now: Date) -> String {
        "\(relativeDay(date, now: now)) · \(time(date))"
    }

    /// "1h 25m", "12m", "now".
    func duration(_ interval: TimeInterval) -> String {
        guard interval > 60 else { return "now" }
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    /// "in 1h 25m" / "25m ago".
    func relativeToNow(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta >= 0 { return "in \(duration(delta))" }
        return "\(duration(-delta)) ago"
    }

    /// "45 minutes" — used for preparation and travel durations.
    func minutesLabel(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // MARK: RelativeTimeFormatting

    func anchorSentence(for title: String, at date: Date) -> String {
        "\(title) starts at \(time(date))."
    }
}
