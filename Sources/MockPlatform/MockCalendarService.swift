import AssistantDomain
import AssistantPlatform
import Foundation

/// In-memory stand-in for the calendar.
///
/// It stores events so the assistant's reads and writes are consistent within a
/// session, and reports `.simulated` so nothing downstream claims an event
/// reached the user's actual calendar.
public actor MockCalendarService: CalendarService {
    public nonisolated var platformName: String { "MockCalendar" }
    public nonisolated var fidelity: PlatformFidelity { .simulated }

    private var storage: [CalendarItem.ID: CalendarItem] = [:]
    private let log: PlatformEventLog?

    public init(log: PlatformEventLog? = nil, seed: [CalendarItem] = []) {
        self.log = log
        for event in seed {
            self.storage[event.id] = event
        }
    }

    public func createEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        var stored = item
        stored.externalIdentifier = "mock-event-\(item.id.rawValue.uuidString.prefix(8))"
        storage[stored.id] = stored

        let receipt = makeReceipt(
            "Calendar event created: \(stored.title) — \(Self.format(stored.start))",
            identifier: stored.externalIdentifier
        )
        await log?.record(receipt)
        return (stored, receipt)
    }

    public func updateEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        guard var stored = storage[item.id] else {
            throw PlatformError.notFound(identifier: item.id.description)
        }
        let externalIdentifier = stored.externalIdentifier
        stored = item
        stored.externalIdentifier = externalIdentifier
        storage[stored.id] = stored

        let receipt = makeReceipt(
            "Calendar event updated: \(stored.title) — \(Self.format(stored.start))",
            identifier: externalIdentifier
        )
        await log?.record(receipt)
        return (stored, receipt)
    }

    public func deleteEvent(id: CalendarItem.ID) async throws -> PlatformReceipt {
        guard let removed = storage.removeValue(forKey: id) else {
            throw PlatformError.notFound(identifier: id.description)
        }
        let receipt = makeReceipt("Calendar event deleted: \(removed.title)")
        await log?.record(receipt)
        return receipt
    }

    public func event(id: CalendarItem.ID) async throws -> CalendarItem? {
        storage[id]
    }

    public func events(in window: TimeWindow) async throws -> [CalendarItem] {
        storage.values
            .filter { window.contains($0.start) }
            .sorted { $0.start < $1.start }
    }

    private func makeReceipt(_ description: String, identifier: String? = nil) -> PlatformReceipt {
        PlatformReceipt(
            description: description,
            fidelity: fidelity,
            platformName: platformName,
            externalIdentifier: identifier
        )
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}
