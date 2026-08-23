import Foundation
import SystemSurfaces

/// A replacement the user has agreed to.
struct KeyboardAssistantAcceptance {
    var text: String
    /// How much of what is already there to remove first. Derived from the
    /// text the request was made about, never from the proxy — a bounded
    /// number, so accepting a suggestion can never become an unbounded delete.
    var charactersToDelete: Int
}

/// The keyboard's whole relationship with the assistant.
///
/// ## The shape of it
///
/// Section 20:
///
///     keyboard → small request → shared container → application → result
///
/// The keyboard writes four fields and reads back at most four. It does not
/// know which provider will answer, whether one is configured, or whether the
/// app is running (sections 23 and 26). It states what it wants and finds out.
///
/// ## Why it cannot simply wait
///
/// Section 23 is the honest part. iOS does not run the containing app on demand
/// because an extension asked it to. If the app is not running, nothing services
/// the request — so this waits briefly, and then says so. It never claims
/// execution is guaranteed, and it never destroys the user's text on the way to
/// finding out.
///
/// ## What it does when it cannot
///
/// Section 24: falls back to the deterministic tidy-up, which is honest about
/// what it is — whitespace and capitalisation, no rewriting — and is offered as
/// that rather than dressed up as the model's answer.
@MainActor
final class KeyboardAssistantBridge {
    private let store: any SystemSurfaceStore
    private var pendingRequestID: UUID?

    /// How long to wait for the application to answer.
    ///
    /// Short on purpose. A keyboard that appears frozen for ten seconds is a
    /// keyboard the user force-quits the host app to escape.
    private let timeout: TimeInterval = 3
    private let pollInterval: TimeInterval = 0.25

    init(store: (any SystemSurfaceStore)? = nil) {
        self.store = store ?? FileSystemSurfaceStore.appGroup()
    }

    /// What the keyboard may offer.
    ///
    /// Section 12: with no shared container — Full Access off — this reports
    /// that assistant actions are unavailable. Typing is unaffected, because
    /// typing never asks this anything.
    func configuration() -> KeyboardConfigurationSnapshot {
        guard store.isAvailable else {
            return .withoutSharedAccess(at: .now)
        }
        return store.readOrPlaceholder(
            KeyboardConfigurationSnapshot.self,
            // A container we can reach but nothing written yet: the app has not
            // been opened since installing. Offer the actions; the request will
            // report honestly if nothing services it.
            fallback: KeyboardConfigurationSnapshot(generatedAt: .now)
        )
    }

    /// Submits one operation and waits, briefly.
    func submit(
        operation: KeyboardAssistantOperation,
        text: String
    ) async -> KeyboardAssistantResult {
        guard store.isAvailable else {
            return .unavailable(
                UUID(),
                reason: "Turn on Full Access in Settings to use assistant actions."
            )
        }

        let request = KeyboardAssistantRequest(
            operation: operation,
            // Tidied first, so what the assistant is asked to improve is not
            // full of double spaces — and so the fallback below is already
            // computed from the same input.
            inputText: KeyboardTextTransform.tidyWhitespace(text),
            createdAt: .now
        )
        pendingRequestID = request.id

        do {
            try store.write(KeyboardExchange(generatedAt: .now, request: request))
        } catch {
            return .unavailable(request.id, reason: "Assistant unavailable")
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard pendingRequestID == request.id else {
                return KeyboardAssistantResult(requestID: request.id, status: .cancelled)
            }
            if let exchange = try? store.read(KeyboardExchange.self),
               let result = exchange.result,
               result.requestID == request.id,
               result.status != .pending {
                pendingRequestID = nil
                return result
            }
        }

        pendingRequestID = nil
        // Section 23: not pretending. The app was not there to answer.
        return .unavailable(
            request.id,
            reason: "Open Personal Assistant once to enable this."
        )
    }

    /// Section 27. Stops waiting; changes nothing the user typed.
    func cancel() {
        pendingRequestID = nil
        // Clear the request so the app does not answer one nobody is waiting
        // for — and, more importantly (section 94), so the user's text does not
        // sit in a shared file after they changed their mind.
        try? store.write(KeyboardExchange(generatedAt: .now))
    }

    /// The deterministic fallback, offered as itself.
    ///
    /// Section 24: whitespace and capitalisation. It is not the model's answer
    /// and is never presented as one.
    static func localFallback(for text: String) -> String? {
        let tidied = KeyboardTextTransform.tidy(text)
        return tidied == text ? nil : tidied
    }
}
