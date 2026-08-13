import AssistantDomain
import AssistantPlatform
import Foundation

/// In-memory stand-in for alarms.
///
/// On iOS this becomes AlarmKit, which is genuinely different from a
/// notification — it sounds through silent mode and must be dismissed. Nothing
/// here emulates that; it only records the intent.
public actor MockAlarmService: AlarmService {
    public nonisolated var platformName: String { "MockAlarms" }
    public nonisolated var fidelity: PlatformFidelity { .simulated }

    private var alarms: [AlarmRequest.ID: AlarmRequest] = [:]
    private let log: PlatformEventLog?

    public init(log: PlatformEventLog? = nil) {
        self.log = log
    }

    public func schedule(_ request: AlarmRequest) async throws -> PlatformReceipt {
        alarms[request.id] = request
        let receipt = makeReceipt(
            "Alarm set: \(request.label) — \(MockCalendarService.format(request.fireDate))",
            identifier: request.id.description
        )
        await log?.record(receipt)
        return receipt
    }

    public func update(
        _ request: AlarmRequest
    ) async throws -> (request: AlarmRequest, receipt: PlatformReceipt) {
        guard alarms[request.id] != nil else {
            throw PlatformError.notFound(identifier: request.id.description)
        }
        alarms[request.id] = request
        let receipt = makeReceipt(
            "Alarm updated: \(request.label) — \(MockCalendarService.format(request.fireDate))",
            identifier: request.id.description
        )
        await log?.record(receipt)
        return (request, receipt)
    }

    public func cancel(id: AlarmRequest.ID) async throws -> PlatformReceipt {
        guard let removed = alarms.removeValue(forKey: id) else {
            throw PlatformError.notFound(identifier: id.description)
        }
        let receipt = makeReceipt("Alarm cancelled: \(removed.label)")
        await log?.record(receipt)
        return receipt
    }

    public func scheduledAlarms() async throws -> [AlarmRequest] {
        alarms.values.sorted { $0.fireDate < $1.fireDate }
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
