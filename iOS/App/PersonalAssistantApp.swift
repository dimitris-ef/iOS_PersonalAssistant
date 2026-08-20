import SwiftUI

/// The application entry point.
///
/// The object graph is built once here and injected into the view tree. No view
/// constructs a service, so swapping the mock platform for the real Apple
/// frameworks is a change in `AppEnvironment` alone.
@main
struct PersonalAssistantApp: App {
    /// Either a running app or an explanation of why there isn't one.
    ///
    /// Persistence is opened once, here, before any view exists. A screen that
    /// opened its own store would be a second store, and two contexts over one
    /// database disagree with each other.
    private enum Startup {
        case ready(AppModel)
        case failed(String)
    }

    @State private var startup: Startup
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system

    init() {
        do {
            let environment = try AppEnvironment.makePersistent()

            // Installed here, in the initialiser, and not later in a `.task`.
            // When someone taps "Done" on a reminder from the lock screen, iOS
            // launches the app and delivers the response almost immediately —
            // a delegate registered once the first view appears is registered
            // too late, and that response is simply never seen. The handler can
            // arrive afterwards; the delegate cannot.
            environment.notificationCoordinator?.install()

            // Hands the app's environment to the App Intents side, so an
            // intent run while the app is open reuses this composition rather
            // than building a second one — and, critically, a second
            // SwiftData container over the same file.
            AppIntentDependencies.adopt(environment)

            _startup = State(initialValue: .ready(AppModel(environment: environment)))
        } catch {
            // Deliberately not a fallback to in-memory storage. The user would
            // get a working-looking app that loses a day's work at
            // termination — and would have no way to know. Better to say so.
            _startup = State(initialValue: .failed(String(describing: error)))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch startup {
                case .ready(let model):
                    RootView()
                        .environment(model)
                        .task { await model.bootstrap() }
                case .failed(let detail):
                    PersistenceFailureView(detail: detail)
                }
            }
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// Light / Dark / System.
///
/// Kept in `@AppStorage` rather than in the domain's `AssistantSettings`,
/// because appearance is a property of this UI and not something the assistant
/// reasons about. `nil` means "follow the system", which is the default.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
