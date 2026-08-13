import AssistantDomain
import AssistantPlatform
import Foundation

/// In-memory stand-in for the system reminders list.
public actor MockReminderService: ReminderService {
    public nonisolated var platformName: String { "MockReminders" }
    public nonisolated var fidelity: PlatformFidelity { .simulated }

    private var storage: [ReminderItem.ID: ReminderItem] = [:]
    private let log: PlatformEventLog?

    public init(log: PlatformEventLog? = nil) {
        self.log = log
    }

    public func createReminder(
        _ item: ReminderItem
    ) async throws -> (item: ReminderItem, receipt: PlatformReceipt) {
        var stored = item
        stored.externalIdentifier = "mock-reminder-\(item.id.rawValue.uuidString.prefix(8))"
        storage[stored.id] = stored

        let due = stored.dueDate.map { " — \(MockCalendarService.format($0))" } ?? ""
        let receipt = makeReceipt(
            "Reminder created: \(stored.title)\(due)",
            identifier: stored.externalIdentifier
        )
        await log?.record(receipt)
        return (stored, receipt)
    }

    public func completeReminder(id: ReminderItem.ID) async throws -> PlatformReceipt {
        guard var stored = storage[id] else {
            throw PlatformError.notFound(identifier: id.description)
        }
        stored.isCompleted = true
        storage[id] = stored

        let receipt = makeReceipt("Reminder completed: \(stored.title)")
        await log?.record(receipt)
        return receipt
    }

    public func reminders(includingCompleted: Bool) async throws -> [ReminderItem] {
        storage.values
            .filter { includingCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?): return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.title < rhs.title
                }
            }
    }

    private func makeReceipt(_ description: String, identifier: String? = nil) -> PlatformReceipt {
        PlatformReceipt(
            description: description,
            fidelity: fidelity,
            platformName: platformName,
            externalIdentifier: identifier
        )
    }
}
