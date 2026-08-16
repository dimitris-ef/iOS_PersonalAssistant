import SwiftUI

/// The four primary destinations, plus the presentations that can appear over
/// any of them.
///
/// Settings is reachable from every screen's header rather than occupying a
/// fifth tab: it is somewhere you visit occasionally, not somewhere you work.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .assistant
    @State private var showsSettings = false

    var body: some View {
        @Bindable var model = model

        TabView(selection: $selectedTab) {
            AssistantScreen()
                .tag(AppTab.assistant)
                .tabItem { Label("Assistant", systemImage: "bubble.left.and.text.bubble.right") }

            TodayScreen()
                .tag(AppTab.today)
                .tabItem { Label("Today", systemImage: "sun.max") }

            TasksScreen()
                .tag(AppTab.tasks)
                .tabItem { Label("Tasks", systemImage: "checklist") }

            MemoryScreen()
                .tag(AppTab.memory)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .environment(\.presentSettings, { showsSettings = true })
        .sheet(isPresented: $showsSettings) {
            SettingsScreen()
        }
        // A simulated reminder can arrive while any tab is showing, so it is
        // presented from the root rather than from a single screen.
        .sheet(item: $model.simulatedReminder) { reminder in
            SimulatedReminderView(reminder: reminder)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // Reminders that came due while the app was closed are caught up here.
        //
        // Deliberately driven by the app becoming active — a domain event —
        // rather than by any screen appearing. Scheduling that happens because
        // a view rendered is scheduling that happens several times.
        //
        // This is a stand-in for real delivery, not a substitute for it: it can
        // only notice a missed reminder once the user opens the app. Catching it
        // at the moment it happens needs UserNotifications. TODO-XCODE.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.reconcileFollowUps() }
        }
        .bannerHost()
    }
}

enum AppTab: Hashable {
    case assistant
    case today
    case tasks
    case memory
}

// MARK: - Settings presentation

/// Lets any screen open Settings without each one owning the sheet.
private struct PresentSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var presentSettings: () -> Void {
        get { self[PresentSettingsKey.self] }
        set { self[PresentSettingsKey.self] = newValue }
    }
}

/// The settings button shown in each screen's toolbar.
struct SettingsToolbarButton: View {
    @Environment(\.presentSettings) private var presentSettings

    var body: some View {
        Button(action: presentSettings) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("Settings")
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    RootView()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
