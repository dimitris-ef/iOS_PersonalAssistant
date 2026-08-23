import Foundation
import XCTest

@testable import SystemSurfaces

/// When a widget should look different, worked out in advance.
///
/// Section 98, and the reason it is a unit test: the alternative is putting a
/// widget on a Home Screen at 2:30 and watching it until 4:00. Every date here
/// is injected, nothing sleeps, and a whole afternoon takes a millisecond.
final class WidgetTimelinePlannerTests: XCTestCase {
    /// 14:00 on a fixed day, so the times below read like the section 35
    /// example rather than like epoch arithmetic.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func at(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    private func snapshot(_ items: [TodaySnapshotItem]) -> TodaySnapshot {
        TodaySnapshot(generatedAt: now, items: items, outstandingCount: items.count)
    }

    /// Section 35, literally.
    ///
    ///     2:35  start getting ready
    ///     3:20  leave
    ///     4:00  work
    ///
    /// Four entries: now, and each of the three transitions. At 3:19 the widget
    /// says "leave at 3:20"; at 3:21 it says "work at 4:00"; between them
    /// nothing of ours ran at all.
    func testATimelineHasAnEntryAtEveryTransition() {
        let start = TodaySnapshotItem(
            id: "prep", title: "Start getting ready", date: at(35), kind: .preparation
        )
        let leave = TodaySnapshotItem(
            id: "leave", title: "Leave", date: at(80), kind: .leave
        )
        let work = TodaySnapshotItem(
            id: "work", title: "Work", date: at(120), kind: .event
        )

        let entries = WidgetTimelinePlanner().entries(
            for: snapshot([start, leave, work]),
            now: now
        )

        XCTAssertEqual(entries.map(\.date), [now, at(35), at(80), at(120)])
        // And each entry knows what is next *at that moment*, which is the
        // whole point — the same snapshot renders differently at each.
        XCTAssertEqual(entries[0].relevantItemID, "prep")
        XCTAssertEqual(entries[1].relevantItemID, "prep")
        XCTAssertEqual(entries[2].relevantItemID, "leave")
        XCTAssertEqual(entries[3].relevantItemID, "work")
    }

    /// A day with nothing in it still comes back for a look. A timeline with
    /// one entry and no successor is a widget that can show yesterday tomorrow.
    func testAnEmptyDayStillSchedulesAQuietRefresh() {
        let planner = WidgetTimelinePlanner(quietRefreshInterval: 3_600)
        let entries = planner.entries(for: snapshot([]), now: now)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].date, now)
        XCTAssertEqual(entries[1].date, now.addingTimeInterval(3_600))
        XCTAssertNil(entries[0].relevantItemID)
    }

    /// Section 34 and 36. A budget exists, so the plan is bounded rather than
    /// one entry per item on a busy day.
    func testTheEntryCountIsBounded() {
        let items = (1...40).map { index in
            TodaySnapshotItem(
                id: "item-\(index)",
                title: "Task \(index)",
                date: at(Double(index) * 5),
                kind: .task
            )
        }

        let entries = WidgetTimelinePlanner(maximumEntries: 6).entries(
            for: snapshot(items),
            now: now
        )
        XCTAssertEqual(entries.count, 6)
    }

    /// Things beyond the horizon are somebody else's timeline. WidgetKit will
    /// ask again long before then, and planning tomorrow from today's data is
    /// planning from data that will have changed.
    func testItemsBeyondTheHorizonAreNotPlannedFor() {
        let soon = TodaySnapshotItem(id: "soon", title: "Soon", date: at(30), kind: .task)
        let distant = TodaySnapshotItem(
            id: "distant", title: "Tomorrow", date: at(60 * 30), kind: .task
        )

        let entries = WidgetTimelinePlanner(horizon: 6 * 3_600).entries(
            for: snapshot([soon, distant]),
            now: now
        )
        XCTAssertEqual(entries.map(\.date), [now, at(30)])
    }

    /// Something already finished is not a moment the display changes at.
    func testCompletedItemsProduceNoTransition() {
        let done = TodaySnapshotItem(
            id: "done", title: "Finished", date: at(20), kind: .task, isDone: true
        )
        let open = TodaySnapshotItem(id: "open", title: "Open", date: at(45), kind: .task)

        let entries = WidgetTimelinePlanner().entries(for: snapshot([done, open]), now: now)
        XCTAssertEqual(entries.map(\.date), [now, at(45)])
    }

    /// Past items do not generate entries either — a widget cannot usefully
    /// change at a moment that has already gone.
    func testPastItemsProduceNoTransition() {
        let past = TodaySnapshotItem(id: "past", title: "Earlier", date: at(-60), kind: .task)
        let entries = WidgetTimelinePlanner().entries(for: snapshot([past]), now: now)

        XCTAssertEqual(entries.count, 2, "only now and the quiet refresh")
        XCTAssertEqual(entries[0].relevantItemID, "past", "still the next thing to show")
    }

    /// The refresh request is never "come back immediately", which WidgetKit
    /// would rightly ignore, and never before the plan is used up.
    func testTheRefreshDateIsBoundedBelowAndAfterTheLastEntry() {
        let planner = WidgetTimelinePlanner(quietRefreshInterval: 2 * 3_600)

        let busy = planner.entries(
            for: snapshot([
                TodaySnapshotItem(id: "a", title: "A", date: at(1), kind: .task),
                TodaySnapshotItem(id: "b", title: "B", date: at(2), kind: .task),
            ]),
            now: now
        )
        // The plan is used up in two minutes, but asking to be woken in two
        // minutes spends the budget for nothing.
        XCTAssertEqual(planner.refreshDate(after: busy, now: now), now.addingTimeInterval(2 * 3_600))

        let spread = planner.entries(
            for: snapshot([
                TodaySnapshotItem(id: "c", title: "C", date: at(300), kind: .task),
            ]),
            now: now
        )
        XCTAssertEqual(planner.refreshDate(after: spread, now: now), at(300))
    }

    /// The same inputs give the same plan, so a widget's behaviour is
    /// reproducible rather than something to observe.
    func testTheTimelineIsDeterministic() {
        let items = [
            TodaySnapshotItem(id: "b", title: "B", date: at(60), kind: .task),
            TodaySnapshotItem(id: "a", title: "A", date: at(30), kind: .task),
        ]

        let planner = WidgetTimelinePlanner()
        let first = planner.entries(for: snapshot(items), now: now)
        let second = planner.entries(for: snapshot(items.reversed()), now: now)
        XCTAssertEqual(first, second)
    }
}
