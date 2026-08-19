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
        // Tapping a real notification opens the task it was about. Presented
        // from the root for the same reason as the sheet above: the
        // notification can arrive on any tab, including none, when it is what
        // launched the app.
        .sheet(item: $model.focusedTask) { focused in
            NavigationStack {
                TaskDetailView(taskID: focused.id)
            }
        }
        // Reminders that came due while the app was closed are caught up here.
        //
        // Deliberately driven by the app becoming active — a domain event —
        // rather than by any screen appearing. Scheduling that happens because
        // a view rendered is scheduling that happens several times.
        //
        // Still needed now that notifications are real. A delivered
        // notification the user never touched produces no callback at all —
        // iOS has nothing to report — so a reminder that was ignored rather
        // than answered is only ever noticed by this sweep.
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
