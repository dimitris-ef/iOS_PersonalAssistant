import AssistantDomain
import AssistantPlatform
import Foundation

/// The alarm service used when AlarmKit is not there.
///
/// ## Why this is not "just send a notification instead"
///
/// It is the obvious fallback and it is the one thing this layer must never do.
/// Someone who asks the assistant to make sure they wake up at six has said
/// something specific: they want the thing that sounds through the ringer
/// switch and through Focus and that has to be dismissed. A notification is not
/// that. It is silenced by the same switch that silences everything else, and
/// it is the exact failure mode — *I thought it was set* — that this app exists
/// to eliminate.
///
/// So on an iPhone running iOS 17 to 25, or on any build whose SDK has no
/// AlarmKit, an alarm request fails and says why. The user finds out at the
/// moment they ask, when they can still set an alarm in Apple's Clock app,
/// rather than at six the next morning.
///
/// `fidelity` is `.simulated` rather than `.live`, which keeps
/// `PlatformServices.isFullyLive` honest — but no receipt is ever produced
/// here, because nothing ever succeeds.
struct UnavailableAlarmService: AlarmService {
    let platformName: String
    let fidelity: PlatformFidelity = .simulated

    /// A sentence written here, never assembled from anything the user typed.
    private let reason: String

    init(platformName: String = "No alarm support", reason: String) {
        self.platformName = platformName
        self.reason = reason
    }

    func schedule(_ request: AlarmRequest) async throws -> PlatformReceipt {
        throw unavailable()
    }

    func update(
        _ request: AlarmRequest
    ) async throws -> (request: AlarmRequest, receipt: PlatformReceipt) {
        throw unavailable()
    }

    func cancel(id: AlarmRequest.ID) async throws -> PlatformReceipt {
        throw unavailable()
    }

    /// Empty rather than an error.
    ///
    /// "What alarms are set?" has a truthful answer on a device that cannot set
    /// alarms, and it is "none". Throwing here would turn an ordinary question
    /// into a failure the UI has to explain.
    func scheduledAlarms() async throws -> [AlarmRequest] { [] }

    private func unavailable() -> PlatformError {
        PlatformError.notAvailable(capability: .alarms, reason: reason)
    }
}
