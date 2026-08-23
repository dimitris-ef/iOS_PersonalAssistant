import Foundation
import SystemSurfaces
import WidgetKit

/// One timeline entry: a moment, and the projection as it reads then.
struct SurfaceEntry<Snapshot: SystemSurfaceSnapshot>: TimelineEntry {
    var date: Date
    var snapshot: Snapshot
    /// True when the app has never written a projection, or the one on disk
    /// could not be read. Views show a neutral "nothing here yet" rather than
    /// an error, and never invented content (section 77).
    var isPlaceholder: Bool = false
}

/// Reads a projection and hands WidgetKit a plan.
///
/// ## What a timeline provider is allowed to do
///
/// Read one file and arrange some dates. That is the whole of it.
///
/// Section 45 is a hard requirement and this is where it is kept: there is no
/// provider, no network and no model reachable from this type — the extension
/// does not link any of them. Section 33 is kept the same way: there is no
/// `DailyPriorityRanker` here either, because the ranking already happened in
/// the app and its answer is in the file.
///
/// ## Why every failure is a placeholder
///
/// A timeline provider has milliseconds, no user to ask and no way to report
/// anything. Sections 37 and 73: an unreadable file produces the best safe
/// representation available, which is an empty one.
struct SnapshotTimelineProvider<Snapshot: SystemSurfaceSnapshot>: TimelineProvider {
    typealias Entry = SurfaceEntry<Snapshot>

    /// Builds the empty value for this snapshot kind.
    let placeholderSnapshot: (Date) -> Snapshot
    /// Turns a snapshot into the moments at which it should redraw. Nil for the
    /// kinds whose display does not change with time.
    var transitions: ((Snapshot, Date) -> [Date])?
    var store: any SystemSurfaceStore = FileSystemSurfaceStore.appGroup()
    var planner = WidgetTimelinePlanner()

    /// Shown in the widget gallery and while the real one loads.
    ///
    /// Section 77: generic, never the user's actual data. A gallery preview
    /// showing somebody's real appointments is a privacy leak in the one place
    /// people browse with the phone held out to somebody else.
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: placeholderSnapshot(.now), isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(currentEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let entry = currentEntry(at: now)

        guard let transitions, !entry.isPlaceholder else {
            // Nothing time-dependent to prepare. Come back on the quiet
            // interval rather than never — section 34.
            completion(
                Timeline(
                    entries: [entry],
                    policy: .after(now.addingTimeInterval(WidgetTimelinePlanner().quietRefreshInterval))
                )
            )
            return
        }

        // Section 35: prepare the future, so the display changes at 3:20
        // without this app running at 3:20.
        let dates = ([now] + transitions(entry.snapshot, now)).sorted()
        let entries = dates.map { date in
            Entry(date: date, snapshot: entry.snapshot, isPlaceholder: false)
        }
        let refresh = planner.refreshDate(
            after: entries.map { WidgetTimelineEntry(date: $0.date) },
            now: now
        )
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    private func currentEntry(at date: Date) -> Entry {
        guard let snapshot = try? store.read(Snapshot.self) else {
            return Entry(date: date, snapshot: placeholderSnapshot(date), isPlaceholder: true)
        }
        return Entry(date: date, snapshot: snapshot, isPlaceholder: false)
    }
}
