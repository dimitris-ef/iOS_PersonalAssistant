import SwiftUI
import WidgetKit

/// Everything this extension publishes.
///
/// Section 82: one extension, several widgets, and the Live Activity too.
/// Apple's architecture allows exactly that, and a separate extension per
/// widget would mean a separate binary, a separate process and a separate copy
/// of everything below it — for three views that read the same file.
@main
struct PersonalAssistantWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        NextTaskWidget()
        SupportWidget()
        liveActivity
    }

    /// The Live Activity, when the SDK has ActivityKit.
    ///
    /// `@WidgetBundleBuilder` handles the availability check; the widget itself
    /// is annotated. On an iPhone below the availability floor the bundle
    /// simply publishes three widgets and no activity — which is section 59's
    /// requirement seen from the other end: nothing else degrades.
    @WidgetBundleBuilder
    private var liveActivity: some Widget {
        if #available(iOS 16.2, *) {
            ExecutiveSupportLiveActivity()
        }
    }
}
