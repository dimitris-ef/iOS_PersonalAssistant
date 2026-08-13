import AssistantDomain
import Foundation

/// Whether a platform service really touches the operating system.
///
/// This is reported honestly all the way up to the user-facing result. On
/// Windows every service is `.simulated`, and nothing in the app is allowed to
/// claim an iPhone action took place.
public enum PlatformFidelity: String, Hashable, Codable, Sendable {
    /// Backed by a real OS framework.
    case live
    /// Recorded in memory only.
    case simulated
}

public protocol PlatformService: Sendable {
    /// A short name for the backing implementation, e.g. "EventKit" or "Mock".
    var platformName: String { get }
    var fidelity: PlatformFidelity { get }
}

public enum PlatformError: Error, Hashable, Sendable {
    case permissionDenied(capability: PlatformCapability)
    case notAvailable(capability: PlatformCapability, reason: String)
    case notFound(identifier: String)
    case invalidRequest(String)
    case underlying(String)
}

public enum PlatformCapability: String, Hashable, Codable, Sendable, CaseIterable {
    case calendar
    case reminders
    case notifications
    case alarms
}

public enum PermissionStatus: String, Hashable, Codable, Sendable {
    case notDetermined
    case granted
    case denied
    /// The capability does not exist on this platform build at all.
    case unsupported
}

/// Permission gate for the sensitive capabilities.
///
/// TODO-XCODE: the real implementation asks EventKit / UserNotifications /
/// AlarmKit for authorization and must be driven from the UI, since iOS
/// requires a foreground prompt.
public protocol PermissionService: Sendable {
    func status(for capability: PlatformCapability) async -> PermissionStatus
    @discardableResult
    func request(_ capability: PlatformCapability) async -> PermissionStatus
}
