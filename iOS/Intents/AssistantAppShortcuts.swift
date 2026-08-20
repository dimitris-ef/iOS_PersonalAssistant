import AppIntents

/// The shortcuts the system offers without the user building anything.
///
/// ## What this gets you
///
/// Everything in here appears in the Shortcuts app automatically, is offered to
/// Siri with the phrases below, and — on an iPhone with an Action Button —
/// becomes assignable under **Settings → Action Button → Shortcut**. The app
/// does not, and cannot, configure the Action Button itself; iOS owns that
/// choice. Providing good shortcuts is the whole of the app's side of it.
///
/// ## Phrase design
///
/// `\(.applicationName)` is required in every phrase — Siri needs to know which
/// app is meant, and hard-coding a name would also break the moment the app is
/// renamed or localised. Two or three phrasings each: enough to cover how
/// people actually speak, few enough that they stay distinguishable. A dozen
/// near-identical phrases make Siri's job harder, not easier.
struct AssistantAppShortcuts: AppShortcutsProvider {

    /// Blue, because it matches the app's accent. Shown behind the shortcut
    /// tile in Shortcuts and on the Action Button configuration screen.
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        // Listed first deliberately: the system treats the leading shortcut as
        // the headline one, and "ask it anything" is both the most useful
        // Action Button assignment and the one that best represents the app.
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask",
            systemImageName: "bubble.left.and.text.bubble.right"
        )

        AppShortcut(
            intent: ShowTodayIntent(),
            phrases: [
                "What's happening today in \(.applicationName)",
                "My day in \(.applicationName)",
            ],
            shortTitle: "Today",
            systemImageName: "sun.max"
        )

        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Create a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
            ],
            shortTitle: "Add Task",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: StoreMemoryIntent(),
            phrases: [
                "Remember this in \(.applicationName)",
                "Tell \(.applicationName) to remember something",
            ],
            shortTitle: "Remember",
            systemImageName: "brain"
        )

        AppShortcut(
            intent: MarkTaskCompleteIntent(),
            phrases: [
                "Complete a task in \(.applicationName)",
                "Mark a task done in \(.applicationName)",
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle"
        )
    }
}
