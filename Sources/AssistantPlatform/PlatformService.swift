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
    /// Withheld by someone other than the user — Screen Time, an MDM profile,
    /// a managed device. Distinct from `denied` because the person holding the
    /// phone cannot fix it in Settings, so telling them to go there is wrong.
    case restricted
    /// Some access was granted, but not enough for what this capability needs.
    ///
    /// The case that exists because iOS 17 lets someone answer the calendar
    /// prompt with "Add Events Only". That is a real, deliberate answer — not a
    /// denial — and collapsing it into either `granted` or `denied` loses the
    /// one fact worth telling the user: which part is missing, and that they
    /// chose it.
    case limited
    /// The capability does not exist on this platform build at all.
    case unsupported

    /// The only status that permits acting.
    ///
    /// A computed property rather than `== .granted` scattered around, so a
    /// future partial-access case cannot be accidentally treated as full
    /// permission by whichever call site was not updated.
    public var allowsAccess: Bool { self == .granted }

    /// True when prompting again cannot change the answer.
    ///
    /// iOS shows its permission alert once. After that a request call returns
    /// the stored decision without displaying anything, so a caller that keeps
    /// asking accomplishes nothing — this is what stops the assistant retrying
    /// a denied capability on every turn.
    public var isSettled: Bool {
        switch self {
        case .notDetermined:
            return false
        case .granted, .denied, .restricted, .unsupported:
            return true
        case .limited:
            // Settled, even though more access exists. iOS shows its prompt
            // once; a second request returns the stored answer without
            // displaying anything. Treating `limited` as unsettled would make
            // every turn call `request` to no visible effect. Widening the
            // grant is a trip to Settings, which is what the message says.
            return true
        }
    }
}

/// Permission gate for the sensitive capabilities.
///
/// Both members are deliberately separate. `status(for:)` never prompts, so
/// the UI can describe the world without changing it; `request(_:)` may put an
/// alert on screen and is therefore only called at the moment the user has
/// asked for something that needs it. Requesting everything at launch is the
/// pattern this split exists to prevent.
public protocol PermissionService: Sendable {
    func status(for capability: PlatformCapability) async -> PermissionStatus
    @discardableResult
    func request(_ capability: PlatformCapability) async -> PermissionStatus
}

extension PermissionService {
    /// The status after asking, but only asking if asking could help.
    ///
    /// This is the shape almost every caller wants: act if already granted,
    /// prompt exactly once if the user has never been asked, and give up
    /// quietly if the answer is already settled. Implemented here so the rule
    /// is written once rather than in each platform service.
    @discardableResult
    public func ensure(_ capability: PlatformCapability) async -> PermissionStatus {
        let current = await status(for: capability)
        guard !current.isSettled else { return current }
        return await request(capability)
    }
}
