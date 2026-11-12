import AssistantDomain
import Foundation

/// Reconnects reminder plans to events created before build 29.
///
/// ## What was broken
///
/// Until build 29 an event the app created was planned under one id and read
/// back from Apple's calendar under another. The reminder plan (and the chat
/// card) kept the first, the calendar list had the second, and neither could
/// find the other: "Event not found" from the card, "No reminders are planned
/// for this yet" from Up Next — for the same event, whose reminders were firing
/// perfectly well.
///
/// New events keep one id now. This finds the old ones: a plan whose event
/// cannot be found is matched to an event with the same title and the same
/// start, and only when exactly one event matches. Anything less certain is
/// left alone — a wrong link would attach someone's reminders to the wrong
/// appointment, which is worse than a broken one.
public enum EventLinkRepair {

    public struct Link: Hashable, Sendable {
        /// The id the calendar knows the event by now.
        public let existing: CalendarItem.ID
        /// The id the reminder plan (and the chat card) hold.
        public let appID: CalendarItem.ID
    }

    /// How far apart two starts may be and still be the same appointment.
    static let startTolerance: TimeInterval = 60

    public static func links(plans: [ReminderPlan], events: [CalendarItem]) -> [Link] {
        let eventIDs = Set(events.map(\.id))
        let referenced = Set(plans.compactMap { plan -> CalendarItem.ID? in
            if case .calendarItem(let id) = plan.subject.reference { return id }
            return nil
        })

        var links: [Link] = []
        var claimed: Set<CalendarItem.ID> = []
        for plan in plans {
            guard case .calendarItem(let appID) = plan.subject.reference,
                !eventIDs.contains(appID),
                let start = plan.subject.anchor.date
            else { continue }

            let title = normalized(plan.subject.title)
            let candidates = events.filter { event in
                // An event another plan already points at is that plan's.
                !referenced.contains(event.id)
                    && !claimed.contains(event.id)
                    && normalized(event.title) == title
                    && abs(event.start.timeIntervalSince(start)) <= startTolerance
            }
            guard candidates.count == 1, let match = candidates.first else { continue }
            claimed.insert(match.id)
            links.append(Link(existing: match.id, appID: appID))
        }
        return links
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
