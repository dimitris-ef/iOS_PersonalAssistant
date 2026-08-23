import SwiftUI
import SystemSurfaces

/// Widgets, the keyboard and Live Activities, explained.
///
/// ## What this screen is for
///
/// Sections 14, 87, 88 and 89 all ask for the same restrained thing: say what
/// exists, say honestly what it needs, and stop. There is no setup wizard here,
/// no permission prompt and — section 14 is explicit — no repeated nagging to
/// turn Full Access on. The keyboard works without it; the screen says so.
///
/// ## Why the keyboard status is not a yes or no
///
/// Because iOS does not reliably tell an app whether its own keyboard is
/// enabled, and section 87 says not to claim certainty where there is none. So
/// this describes the path through Settings rather than asserting a state it
/// cannot observe.
struct SystemSurfacesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SystemSurfaceSettings.liveActivitiesKey) private var liveActivities = true
    @AppStorage(SystemSurfaceSettings.keyboardAssistantKey) private var keyboardAssistant = true

    var body: some View {
        Form {
            widgetsSection
            keyboardSection
            liveActivitySection
        }
        .navigationTitle("Widgets & Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Widgets

    /// Section 88: a short explanation, not a settings screen. Widgets are
    /// added from the system's own gallery and there is nothing here to
    /// configure.
    private var widgetsSection: some View {
        Section {
            Label("Today", systemImage: "list.bullet")
            Label("Next Task", systemImage: "circle")
            Label("Support", systemImage: "arrow.right.circle")
        } header: {
            Text("Widgets")
        } footer: {
            Text(
                """
                Touch and hold the Home Screen or Lock Screen, tap Edit, then \
                Add Widget and choose Personal Assistant. Widgets show what the \
                app already knows — they never contact a model.
                """
            )
        }
    }

    // MARK: Keyboard

    private var keyboardSection: some View {
        Section {
            Toggle("Assistant actions", isOn: $keyboardAssistant)
                .onChange(of: keyboardAssistant) { _, enabled in
                    Task { await model.setKeyboardAssistantEnabled(enabled) }
                }
        } header: {
            Text("Keyboard")
        } footer: {
            // Section 14's wording, matched to what is actually implemented.
            Text(
                """
                Add the keyboard in Settings › General › Keyboard › Keyboards › \
                Add New Keyboard, then choose Personal Assistant.

                Typing works straight away. Improve, Shorten, Fix Grammar and \
                Ask Assistant need Full Access, which is what lets the keyboard \
                hand text to this app — the app answers, and the keyboard \
                inserts the result only when you accept it. Without Full Access \
                the keyboard still types normally and those buttons say they are \
                unavailable.

                The keyboard never stores what you type in other apps.
                """
            )
        }
    }

    // MARK: Live Activities

    /// Section 89. The app's own switch, honoured independently of iOS's — a
    /// user who has allowed Live Activities system-wide may still not want them
    /// from this app, and the reverse is not something this app can override.
    private var liveActivitySection: some View {
        Section {
            Toggle("Show Live Activities", isOn: $liveActivities)
                .onChange(of: liveActivities) { _, enabled in
                    Task { await model.setLiveActivitiesEnabled(enabled) }
                }
        } header: {
            Text("Live Activities")
        } footer: {
            Text(
                """
                Shows a countdown on the Lock Screen and in the Dynamic Island \
                while you are getting ready for something important, or while a \
                task you started is under way. Not for every task — only for \
                what is happening now.

                Live Activities can also be switched off for every app in \
                Settings › Face ID & Passcode.
                """
            )
        }
    }
}

/// The two `@AppStorage` keys this screen owns.
///
/// Named here rather than typed out at each use, for the same reason
/// `SystemSurfaceIdentifiers` exists: a mistyped key is a toggle that silently
/// controls nothing.
enum SystemSurfaceSettings {
    static let liveActivitiesKey = "systemSurfaces.liveActivities"
    static let keyboardAssistantKey = "systemSurfaces.keyboardAssistant"

    static var liveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: liveActivitiesKey) as? Bool ?? true
    }

    static var keyboardAssistantEnabled: Bool {
        UserDefaults.standard.object(forKey: keyboardAssistantKey) as? Bool ?? true
    }
}

// TODO-XCODE: never rendered.
#Preview {
    NavigationStack {
        SystemSurfacesView()
    }
    .environment(AppModel(environment: .makeDemo()))
}
