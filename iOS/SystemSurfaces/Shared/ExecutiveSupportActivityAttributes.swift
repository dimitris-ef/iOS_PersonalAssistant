import Foundation
import SystemSurfaces

#if canImport(ActivityKit)
import ActivityKit
#endif

/// The ActivityKit shape of an active support session.
///
/// ## Why this file is so thin
///
/// Section 49 asks that ActivityKit types stay out of the core, and this is
/// where that rule is paid for. The entire content of a Live Activity is
/// `SupportActivityContent`, which lives in the `SystemSurfaces` package, is
/// plain `Codable`, and is what every test asserts on. What is here is a
/// wrapper that makes ActivityKit accept it.
///
/// The consequence is worth stating: the decision of *what a Live Activity
/// says* is made and tested in a package target that cannot import ActivityKit,
/// so it is exercised by CI on a machine with no Lock Screen. Only the last
/// copy — this file, and the views in the widget extension — needs a device.
///
/// ## Availability
///
/// ActivityKit arrived in iOS 16.1 and the app targets iOS 17, so the framework
/// is always present on a supported device. The `canImport` guard is for the
/// package's other platforms and for a Mac build, not for the phone.
#if canImport(ActivityKit)
@available(iOS 16.2, *)
struct ExecutiveSupportActivityAttributes: ActivityAttributes {
    /// The changing half. ActivityKit serializes this on every update and the
    /// system enforces a size limit, which is the practical reason section 50
    /// exists — and the reason `SupportActivityContent` is six small fields.
    struct ContentState: Codable, Hashable {
        var content: SupportActivityContent

        init(content: SupportActivityContent) {
            self.content = content
        }
    }

    /// The fixed half: what this activity is about, decided once when it starts.
    ///
    /// The task identifier is here rather than in the content state because it
    /// never changes, and because the interactive controls need it to address
    /// an App Intent — a Done button has to know what it is completing.
    var taskID: UUID
    var kind: SupportActivityKind

    init(taskID: UUID, kind: SupportActivityKind) {
        self.taskID = taskID
        self.kind = kind
    }
}
#endif
