import SwiftUI

/// The application entry point.
///
/// The object graph is built once here and injected into the view tree. No view
/// constructs a service, so swapping the mock platform for the real Apple
/// frameworks is a change in `AppEnvironment` alone.
@main
struct PersonalAssistantApp: App {
    @State private var model: AppModel
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system

    init() {
        // TODO-XCODE: `makeDemo()` uses mock platform services and in-memory
        // storage. Replace with the live environment once the Apple layer
        // exists — nothing in the UI changes when that happens.
        _model = State(initialValue: AppModel(environment: AppEnvironment.makeDemo()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.bootstrap() }
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
