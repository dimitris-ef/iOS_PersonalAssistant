import Foundation
import SystemSurfaces

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Asks WidgetKit to rebuild one widget's timeline.
///
/// Section 76: `reloadTimelines(ofKind:)`, never `reloadAllTimelines()`. The
/// difference is a refresh budget the system will otherwise stop honouring —
/// reloading three widgets because one task changed spends three times what
/// the change was worth, and the widget that goes stale as a result is
/// whichever one the user was looking at.
///
/// The decision about *which* kinds changed is made in `SystemSurfaceService`,
/// which compares the new projection against the stored one. This type does as
/// it is told and nothing more, which is what makes the restraint testable
/// without WidgetKit.
struct WidgetCenterReloader: SystemSurfaceReloader {
    func reload(_ kind: SystemSurfaceWidgetKind) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
        #endif
    }
}
