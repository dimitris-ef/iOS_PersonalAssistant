import AssistantPlatform
import Foundation

/// Answers "may we?" for each capability, by asking whichever Apple framework
/// owns it.
///
/// Built from closures rather than from stored framework objects, for one
/// reason worth the indirection: the set of capabilities that *exist* varies by
/// SDK and by OS version. AlarmKit is absent from a Mac's SDK and from every
/// iPhone before iOS 26. Rather than a struct with conditionally-compiled
/// stored properties — which is how one `#if` becomes fifteen — a capability
/// with no entry in the table is simply `unsupported`, which is the truth and
/// needs no special case anywhere else.
struct ApplePermissionService: PermissionService {
    typealias Query = @Sendable () async -> PermissionStatus

    private let queries: [PlatformCapability: Query]
    private let requests: [PlatformCapability: Query]

    init(
        queries: [PlatformCapability: Query],
        requests: [PlatformCapability: Query]
    ) {
        self.queries = queries
        self.requests = requests
    }

    func status(for capability: PlatformCapability) async -> PermissionStatus {
        guard let query = queries[capability] else { return .unsupported }
        return await query()
    }

    /// Prompts. Only ever called from `PermissionService.ensure`, or by a
    /// deliberate user action — never on a timer and never at launch.
    @discardableResult
    func request(_ capability: PlatformCapability) async -> PermissionStatus {
        guard let request = requests[capability] else { return .unsupported }
        let status = await request()
        // The capability name and the resulting state, which are both fixed
        // vocabulary. Nothing about what the user was trying to do.
        ApplePlatformLog.debug("Permission \(capability.rawValue): \(status.rawValue)")
        return status
    }
}
