import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(UserNotifications)
import UserNotifications

/// The `UNUserNotificationCenterDelegate`, and nothing more than that.
///
/// ## What this deliberately does not contain
///
/// No task lookup, no status machine, no repository, no SwiftData. A
/// notification callback is a hostile place for business logic: it arrives on
/// the main thread at an arbitrary moment, it can arrive during launch before
/// the app has finished assembling itself, and it can arrive twice. Code that
/// writes to a database from there is how duplicated completions and
/// half-migrated stores happen.
///
/// So this class does three things — convert Apple's response into a value
/// type, ask `AppleNotificationRouter` what it means, and hand the answer to
/// whoever is listening. The decision is a pure function tested without a
/// device; the effect goes through `FollowUpService`, the same one door the UI
/// buttons use.
public final class AppleNotificationCoordinator: NSObject, @unchecked Sendable {

    public typealias Handler = @Sendable (AppleNotificationRoute) async -> Void

    private let lock = NSLock()
    private var handler: Handler?
    /// Responses that arrived before anything was listening.
    private var queued: [AppleNotificationRoute] = []

    public override init() {
        super.init()
    }

    /// Starts receiving responses.
    ///
    /// Called at launch, before the environment is built, because the delegate
    /// has to be in place *before* iOS delivers the response that launched the
    /// app. A notification action tapped on the lock screen wakes the process
    /// and delivers immediately; a delegate installed later in the launch
    /// sequence simply never hears about it, and the user's "Done" is lost.
    /// Not main-actor-isolated, deliberately. It is called from the `App`'s
    /// initialiser, which runs before any actor context is established, and
    /// setting the delegate is documented as safe from any thread.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Connects the routes to whatever performs them, replaying anything that
    /// arrived first.
    ///
    /// The replay is the reason this is a two-step setup. Between `install()`
    /// and the repositories being open there is a real window — a cold launch
    /// from a notification action lands inside it every time — and dropping
    /// the response would mean a dismissal that never escalated or a
    /// completion the user has to make twice.
    public func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        let pending = queued
        queued.removeAll()
        lock.unlock()

        guard !pending.isEmpty else { return }
        Task {
            for route in pending {
                await handler(route)
            }
        }
    }

    private func deliver(_ route: AppleNotificationRoute) async {
        lock.lock()
        let handler = self.handler
        if handler == nil {
            queued.append(route)
        }
        lock.unlock()

        guard let handler else { return }
        await handler(route)
    }

    /// Apple's response, reduced to values this module can reason about.
    ///
    /// Nothing of the notification's *content* is read — not the title, not the
    /// body. Only the identifier, the action and the routing payload, which is
    /// all the router is allowed to see anyway.
    private static func response(from response: UNNotificationResponse) -> AppleNotificationResponse {
        var userInfo: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            userInfo[key] = value
        }
        return AppleNotificationResponse(
            systemIdentifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        )
    }
}

extension AppleNotificationCoordinator: UNUserNotificationCenterDelegate {

    /// The user answered a reminder.
    ///
    /// The completion-handler form rather than the `async` one on purpose.
    /// Both exist, but every method on this protocol is optional, so a
    /// signature the runtime does not recognise produces no compile error and
    /// no callback — the failure would be a delegate that is simply never
    /// called, discovered only on a device.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = AppleNotificationRouter.route(Self.response(from: response))

        // Logged as a case name only. Which button was pressed on which kind of
        // reminder is diagnostic; what the reminder said is the user's life.
        ApplePlatformLog.debug("Notification response routed: \(Self.name(of: route))")

        let sendableCompletion = UncheckedSendableBox(completionHandler)
        Task {
            await deliver(route)
            // Called after the work, not before. iOS may suspend the app once
            // this returns, and a dismissal that has not reached the store yet
            // would be lost with it.
            await MainActor.run { sendableCompletion.value() }
        }
    }

    /// A reminder came due while the user was looking at the app.
    ///
    /// Shown anyway. The default is to suppress it, on the reasonable theory
    /// that an app on screen can present its own UI — but this app's whole
    /// premise is that its reminders are the thing that gets through, and
    /// silently swallowing one because the user happened to be reading the
    /// conversation is the wrong instinct here.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private static func name(of route: AppleNotificationRoute) -> String {
        switch route {
        case .outcome: return "outcome"
        case .open: return "open"
        case .ignored: return "ignored"
        }
    }
}

/// Carries a non-`Sendable` completion handler into a `Task`.
///
/// The handler comes from UIKit and is documented to be callable from any
/// thread; the compiler cannot know that. Wrapping it is narrower than making
/// the whole delegate unchecked, and keeps the unchecked claim next to the one
/// value it is being made about.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
