import Foundation

/// One moment at which a widget should look different.
public struct WidgetTimelineEntry: Hashable, Sendable {
    public var date: Date
    /// The snapshot as it should read at that moment. The same snapshot each
    /// time — what changes is which item is "next", which the widget derives
    /// from the entry date.
    public var relevantItemID: String?

    public init(date: Date, relevantItemID: String? = nil) {
        self.date = date
        self.relevantItemID = relevantItemID
    }
}

/// Works out when a widget's content stops being true.
///
/// ## Why this is not "reload every minute"
///
/// Section 34, and it is a platform fact rather than a preference: WidgetKit
/// gives an app a budget of refreshes per day, and an app that asks for one a
/// minute gets refused and then shows the same stale entry for hours. The
/// supported approach is the opposite — hand the system the *future*, ahead of
/// time, and let it swap entries with no process of ours running at all.
///
/// ## The shape of the answer
///
/// Section 35's example is exactly this. Given
///
///     2:35  start getting ready
///     3:20  leave
///     4:00  work
///
/// the timeline is three entries at those three times, plus one for now. At
/// 3:19 the widget says "Leave at 3:20"; at 3:21 it says "Work at 4:00"; and
/// between them nothing ran. The app is not woken, no budget is spent, and the
/// display is right the whole way through.
///
/// Pure and clock-injected, so the plan for a day that has not happened yet is
/// a unit test rather than an afternoon of watching a Home Screen.
public struct WidgetTimelinePlanner: Sendable {
    /// How many entries to prepare. Past this the day is mostly guesswork
    /// anyway, and WidgetKit will have asked again long before.
    public var maximumEntries: Int
    /// How far ahead to plan. A timeline that ends is a timeline the system
    /// comes back for; one that runs to next week is one that goes stale
    /// silently.
    public var horizon: TimeInterval
    /// The longest a widget goes without any refresh at all, when nothing in
    /// the data suggests a moment worth changing at.
    public var quietRefreshInterval: TimeInterval

    public init(
        maximumEntries: Int = 12,
        horizon: TimeInterval = 12 * 3_600,
        quietRefreshInterval: TimeInterval = 4 * 3_600
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.horizon = max(3_600, horizon)
        self.quietRefreshInterval = max(900, quietRefreshInterval)
    }

    /// The entries for a day.
    ///
    /// Always starts with `now`, so the widget has something to draw the moment
    /// it is added. Every later entry is the exact moment an item stops being
    /// in the future — which is when "up next" changes, and therefore the only
    /// times the display needs to differ.
    public func entries(for snapshot: TodaySnapshot, now: Date) -> [WidgetTimelineEntry] {
        let deadline = now.addingTimeInterval(horizon)
        let transitions = snapshot.items
            .filter { !$0.isDone && $0.date > now && $0.date <= deadline }
            .map(\.date)
            .sorted()

        var dates: [Date] = [now]
        for transition in transitions where !dates.contains(transition) {
            dates.append(transition)
            if dates.count >= maximumEntries { break }
        }

        // Nothing scheduled: come back in a while rather than never. A widget
        // whose timeline is a single entry with no end is one that can be
        // showing yesterday tomorrow.
        if dates.count == 1 {
            dates.append(now.addingTimeInterval(quietRefreshInterval))
        }

        return dates.map { date in
            WidgetTimelineEntry(
                date: date,
                relevantItemID: snapshot.next(at: date)?.id
            )
        }
    }

    /// When to ask the system for a fresh timeline.
    ///
    /// After the last prepared entry, because by then the plan has been used
    /// up. Bounded below so a snapshot full of items in the next minute cannot
    /// produce a request to come back immediately, which WidgetKit would
    /// rightly ignore.
    public func refreshDate(after entries: [WidgetTimelineEntry], now: Date) -> Date {
        let last = entries.last?.date ?? now
        let earliest = now.addingTimeInterval(quietRefreshInterval)
        return max(last, earliest)
    }
}
