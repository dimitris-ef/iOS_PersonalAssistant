import AssistantDomain
import AssistantPlatform
import Foundation

/// In-memory stand-in for local notifications.
public actor MockNotificationService: NotificationService {
    public nonisolated var platformName: String { "MockNotifications" }
    public nonisolated var fidelity: PlatformFidelity { .simulated }

    private var pending: [NotificationRequest.ID: NotificationRequest] = [:]
    private let log: PlatformEventLog?

    public init(log: PlatformEventLog? = nil) {
        self.log = log
    }

    public func schedule(_ request: NotificationRequest) async throws -> PlatformReceipt {
        pending[request.id] = request
        let confirmationNote = request.requiresCompletionConfirmation ? " (needs confirmation)" : ""
        let receipt = makeReceipt(
            "Notification scheduled: \(request.title) — \(MockCalendarService.format(request.fireDate))"
                + " [\(request.escalation.rawValue)]\(confirmationNote)",
            identifier: request.id.description
        )
        await log?.record(receipt)
        return receipt
    }

    public func cancel(id: NotificationRequest.ID) async throws -> PlatformReceipt {
        guard let removed = pending.removeValue(forKey: id) else {
            throw PlatformError.notFound(identifier: id.description)
        }
        let receipt = makeReceipt("Notification cancelled: \(removed.title)")
        await log?.record(receipt)
        return receipt
    }

    public func pendingNotifications() async throws -> [NotificationRequest] {
        pending.values.sorted { $0.fireDate < $1.fireDate }
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
