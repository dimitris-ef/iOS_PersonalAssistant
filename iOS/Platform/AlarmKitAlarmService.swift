// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantDomain
import AssistantPlatform
import Foundation

// AlarmKit needs a much newer SDK than this target's deployment minimum, so the
// whole file is guarded. Nothing references this type yet.
// TODO-XCODE: raise the deployment target and drop the guard when adopting it.
#if canImport(AlarmKit)
import AlarmKit

/// AlarmKit-backed alarms.
///
/// Alarms are a genuinely different capability from notifications — they sound
/// through silent mode and Focus, and they must be dismissed. That is why
/// `AlarmService` is its own protocol rather than a flag on the notification
/// service, and why "make sure I actually wake up" routes here.
actor AlarmKitAlarmService: AlarmService {
    nonisolated var platformName: String { "AlarmKit" }
    nonisolated var fidelity: PlatformFidelity { .simulated } // TODO-XCODE: .live once implemented

    func schedule(_ request: AlarmRequest) async throws -> PlatformReceipt {
        // TODO-XCODE: request AlarmKit authorization, build the alarm from
        // `fireDate`, `label` and the snooze settings, and schedule it.
        throw PlatformError.notAvailable(capability: .alarms, reason: "TODO-XCODE: AlarmKit not implemented")
    }

    func update(
        _ request: AlarmRequest
    ) async throws -> (request: AlarmRequest, receipt: PlatformReceipt) {
        throw PlatformError.notAvailable(capability: .alarms, reason: "TODO-XCODE: AlarmKit not implemented")
    }

    func cancel(id: AlarmRequest.ID) async throws -> PlatformReceipt {
        throw PlatformError.notAvailable(capability: .alarms, reason: "TODO-XCODE: AlarmKit not implemented")
    }

    func scheduledAlarms() async throws -> [AlarmRequest] {
        throw PlatformError.notAvailable(capability: .alarms, reason: "TODO-XCODE: AlarmKit not implemented")
    }
}
#endif
