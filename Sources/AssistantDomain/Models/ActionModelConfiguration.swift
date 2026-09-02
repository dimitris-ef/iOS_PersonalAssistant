import Foundation

/// Which model interprets phone actions, and whether the action path is on.
///
/// ## Why this is not `selectedLocalModelID`
///
/// Section 1, and it is the whole point of Part 3. `selectedLocalModelID` is
/// the model the user chose to *talk to* when Local AI is their assistant.
/// This is the model the app uses to *understand a request to do something*.
/// They are answers to different questions, asked by different people — the
/// user picks the first, the app needs the second — and folding them together
/// is precisely the coupling Parts 1 and 2 removed.
///
/// Kept separate, these become independently valid:
///
/// | Chat | Action |
/// | --- | --- |
/// | Apple Foundation Models | a small local GGUF |
/// | a remote provider | a small local GGUF |
/// | a 3B local model | a 0.5B local model |
///
/// Changing either leaves the other alone, which `ActionModelLifecycleTests`
/// asserts in both directions.
///
/// ## What is deliberately not here
///
/// Section 54: an identifier and a flag. No loaded pointer, no context handle,
/// no KV state, no generation buffer — none of which survives a process, and
/// all of which would be a lie if written to disk. After a relaunch the model
/// is *selected* and *unloaded*, and the first action request loads it.
public struct ActionModelConfiguration: Hashable, Codable, Sendable {

    /// The installed local model to interpret actions with, if one is chosen.
    ///
    /// An `AIModelIdentifier` rather than a file path: paths move between
    /// installs and a stale one is a crash waiting for a reinstall, while an
    /// identifier that no longer resolves is simply "not installed any more",
    /// which is a state the UI can show and the action path can fail safely on.
    public var selectedModelID: AIModelIdentifier?

    /// Whether the dedicated action path may run at all.
    ///
    /// Separate from having a model selected, because "I have not chosen one
    /// yet" and "I have turned this off" are different situations and only one
    /// of them is worth prompting somebody about.
    public var isEnabled: Bool

    public init(selectedModelID: AIModelIdentifier? = nil, isEnabled: Bool = true) {
        self.selectedModelID = selectedModelID
        self.isEnabled = isEnabled
    }

    /// Nothing chosen. The action path reports itself unavailable with a reason
    /// the user can act on, and never silently borrows the chat model.
    public static let none = ActionModelConfiguration()

    /// Whether an action request could even be attempted.
    public var isConfigured: Bool { isEnabled && selectedModelID != nil }
}
