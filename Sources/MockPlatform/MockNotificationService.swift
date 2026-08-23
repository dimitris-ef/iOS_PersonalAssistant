import AssistantDomain
import AssistantPlatform
import Foundation

/// In-memory stand-in for local notifications.
public actor MockNotificationService: NotificationService {
    public nonisolated var platformName: String { "MockNotifications" }
    public nonisolated var fidelity: PlatformFidelity { .simulated }

    /// How the next scheduling attempt should behave.
    ///
    /// Part 11 needs the failure paths tested — permission denied, a transient
    /// refusal, a retry that succeeds — and none of them can be produced by
    /// asking a real notification centre nicely. Injected here rather than in a
    /// second mock in the test target, because two stand-ins for one service
    /// drift apart.
    public enum Behaviour: Sendable {
        case succeed
        /// Fails every time, for a reason that will not change. What a user who
        /// has switched notifications off looks like.
        case permissionDenied
        /// Fails the next `count` attempts, then succeeds. The transient case.
        case failTransiently(count: Int)
    }

    private var pending: [NotificationRequest.ID: NotificationRequest] = [:]
    private let log: PlatformEventLog?
    private var behaviour: Behaviour = .succeed
    /// Every request this service was asked to schedule, including the ones it
    /// refused. Lets a test assert that a retry did not become a duplicate.
    public private(set) var scheduleAttempts: [NotificationRequest.ID] = []
    public private(set) var cancelAttempts: [NotificationRequest.ID] = []

    public init(log: PlatformEventLog? = nil) {
        self.log = log
    }

    public func setBehaviour(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    public func schedule(_ request: NotificationRequest) async throws -> PlatformReceipt {
        scheduleAttempts.append(request.id)

        switch behaviour {
        case .succeed:
            break
        case .permissionDenied:
            throw PlatformError.permissionDenied(capability: .notifications)
        case .failTransiently(let count):
            guard count > 0 else { break }
            behaviour = .failTransiently(count: count - 1)
            throw PlatformError.underlying("temporary scheduling failure")
        }

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
        cancelAttempts.append(id)
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
