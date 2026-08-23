import AssistantCore
import Foundation
import SystemSurfaces

#if canImport(ActivityKit)
import ActivityKit
#endif

/// The only place in the application that talks to ActivityKit.
///
/// ## What it is allowed to decide
///
/// Nothing. It starts what it is told to start, updates what it is told to
/// update, ends what it is told to end. Section 48: the coordinator is a
/// presentation adapter, and the decision about which task deserves an activity
/// was made by `LiveActivityPresentationPolicy` in a package target with tests.
///
/// ## Why the failures are all silent
///
/// Section 84. Every call here can fail for reasons that have nothing to do
/// with the user's task: Live Activities switched off, the system's per-app
/// budget reached, an OS below the availability floor. None of them is a reason
/// for a reminder not to fire or a task not to complete, so each one produces a
/// nil identifier or a no-op and the caller carries on.
///
/// ## Dismissal
///
/// Every activity is given a dismissal date when it ends, and a stale date
/// while it runs. Section 53: an activity nobody ends sits on the Lock Screen
/// indefinitely, and "the app was terminated" must not be one of the ways that
/// happens.
final class AppleLiveActivityCoordinator: LiveActivityCoordinator, @unchecked Sendable {

    var isAvailable: Bool {
        get async {
            #if canImport(ActivityKit) && os(iOS)
            if #available(iOS 16.2, *) {
                return ActivityAuthorizationInfo().areActivitiesEnabled
            }
            #endif
            return false
        }
    }

    func start(_ descriptor: LiveActivityDescriptor) async -> String? {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            do {
                let activity = try Activity.request(
                    attributes: ExecutiveSupportActivityAttributes(
                        taskID: descriptor.id,
                        kind: descriptor.kind
                    ),
                    content: ActivityContent(
                        state: .init(content: descriptor.content),
                        // The system removes it by itself at this point even if
                        // this app never runs again.
                        staleDate: descriptor.staleAt
                    ),
                    // Section 55: local updates only. No push token is
                    // requested, and no push infrastructure exists for this
                    // milestone to depend on.
                    pushType: nil
                )
                return activity.id
            } catch {
                // Budget reached, or the user switched them off between the
                // availability check and here. Not an error anybody needs to
                // hear about — the reminder still fires.
                return nil
            }
        }
        #endif
        return nil
    }

    func update(_ descriptor: LiveActivityDescriptor) async {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            guard let activity = activity(for: descriptor) else { return }
            await activity.update(
                ActivityContent(
                    state: .init(content: descriptor.content),
                    staleDate: descriptor.staleAt
                )
            )
        }
        #endif
    }

    func end(_ descriptor: LiveActivityDescriptor) async {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            guard let activity = activity(for: descriptor) else { return }
            var finished = descriptor.content
            finished.phase = .finished
            await activity.end(
                ActivityContent(state: .init(content: finished), staleDate: nil),
                // Immediately: an activity for something that is over is the
                // most annoying possible thing to leave on a Lock Screen.
                dismissalPolicy: .immediate
            )
        }
        #endif
    }

    func runningActivityIDs() async -> Set<String> {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            return Set(Activity<ExecutiveSupportActivityAttributes>.activities.map(\.id))
        }
        #endif
        return []
    }

    #if canImport(ActivityKit) && os(iOS)
    /// Finds the running activity, by the system identifier when the app knows
    /// it and by the task otherwise.
    ///
    /// The fallback is what makes a relaunch work: `Activity.activities` is the
    /// system telling this process what it is already showing, and matching on
    /// the task id in the attributes is how an activity started before the
    /// relaunch is recognised rather than duplicated (section 54).
    @available(iOS 16.2, *)
    private func activity(
        for descriptor: LiveActivityDescriptor
    ) -> Activity<ExecutiveSupportActivityAttributes>? {
        let running = Activity<ExecutiveSupportActivityAttributes>.activities
        if let identifier = descriptor.systemActivityID,
           let match = running.first(where: { $0.id == identifier }) {
            return match
        }
        return running.first { $0.attributes.taskID == descriptor.id }
    }
    #endif
}
