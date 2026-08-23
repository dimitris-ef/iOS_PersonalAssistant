import AssistantDomain
import SwiftUI
import SystemSurfaces

/// The four primary destinations, plus the presentations that can appear over
/// any of them.
///
/// Settings is reachable from every screen's header rather than occupying a
/// fifth tab: it is somewhere you visit occasionally, not somewhere you work.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLifecycle) private var lifecycle
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
        // The view *notices* the phase change; it does not decide what one
        // means. Section 77 — everything below this line is one call into an
        // application-level coordinator, so a view being recreated, appearing
        // twice or being replaced by a preview cannot change whether the user's
        // reminders get reconciled.
        .onChange(of: scenePhase) { _, phase in
            guard let lifecycle else { return }
            switch phase {
            case .active:
                Task { await lifecycle.applicationDidBecomeActive() }
            case .background:
                Task { await lifecycle.applicationDidEnterBackground() }
            default:
                break
            }
        }
        // Section 44. A widget's deep link, parsed by the one type that knows
        // how to build them — so a widget cannot open a destination the app
        // does not have, and adding one is a change in `SystemSurfaceDestination`
        // rather than in a string here.
        .onOpenURL { url in
            guard let destination = SystemSurfaceDestination.parse(url) else { return }
            switch destination {
            case .today:
                selectedTab = .today
            case .assistant:
                selectedTab = .assistant
            case .task(let id):
                selectedTab = .tasks
                model.focusTask(TaskItem.ID(id))
            }
        }
        .bannerHost()
    }
}

/// Reaches the lifecycle coordinator from the view tree.
///
/// An environment value rather than a singleton: previews and the demo launch
/// legitimately have no coordinator, and `nil` there is better than a shared
/// instance quietly reconciling a preview's throwaway store.
private struct AppLifecycleKey: EnvironmentKey {
    static let defaultValue: AppLifecycleCoordinator? = nil
}

extension EnvironmentValues {
    var appLifecycle: AppLifecycleCoordinator? {
        get { self[AppLifecycleKey.self] }
        set { self[AppLifecycleKey.self] = newValue }
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
