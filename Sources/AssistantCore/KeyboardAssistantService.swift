import AssistantDomain
import Foundation
import SystemSurfaces

/// Answers the keyboard, from inside the application.
///
/// ## The half of the bridge that lives here
///
/// The keyboard writes a request into the shared container and waits. This is
/// what reads it. It runs in the *app's* process — never the extension's —
/// which is what section 15 and section 16 are really asking for: the model,
/// whichever one it is, is loaded where there is memory for it.
///
/// ## Two paths, and the difference matters
///
/// - **Transformations** (Improve, Shorten, Fix Grammar) go through
///   `AssistantEngine.transformText`, which offers the model *no tools* and
///   persists nothing. Section 25 is satisfied structurally: "shorten this"
///   cannot create a calendar event because there is no calendar tool in the
///   request.
/// - **Ask Assistant** goes through `AssistantCommandService.ask`, which is the
///   full pipeline — context, memory, the agent loop, decoding, validation,
///   authorization, execution. Section 25's other half: if the user's question
///   does lead to a tool, it enters exactly the same door every other tool call
///   enters, and the keyboard has no say in any of it.
///
/// Neither path lets the keyboard choose a provider, name a model or see one.
/// Section 26: it submits an application-level request and reads back a string.
public struct KeyboardAssistantService: Sendable {
    private let engine: AssistantEngine
    private let commands: AssistantCommandService
    private let store: any SystemSurfaceStore
    private let dateProvider: any DateProvider

    public init(
        engine: AssistantEngine,
        commands: AssistantCommandService,
        store: any SystemSurfaceStore,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.engine = engine
        self.commands = commands
        self.store = store
        self.dateProvider = dateProvider
    }

    /// Services whatever is waiting, if anything is.
    ///
    /// Called when the app becomes active and after a turn — the moments it is
    /// actually running. Deliberately **not** a loop, a timer or a background
    /// service: section 92 forbids a daemon, and iOS would not run one anyway.
    /// A request nobody serviced times out in the keyboard and says so, which
    /// is section 23's honesty about execution not being guaranteed.
    @discardableResult
    public func servicePendingRequest() async -> KeyboardAssistantResult? {
        guard store.isAvailable else { return nil }
        guard
            let exchange = try? store.read(KeyboardExchange.self),
            let request = exchange.request
        else { return nil }

        // Already answered. The keyboard clears the request when it takes the
        // result, so a stale one here means the app was not running when it was
        // made and the keyboard has since given up.
        if let existing = exchange.result, existing.requestID == request.id {
            return existing
        }
        guard !isExpired(request) else {
            // Section 94: an abandoned request is not left sitting in a shared
            // file with the user's half-written message in it.
            try? store.write(KeyboardExchange(generatedAt: dateProvider.now))
            return nil
        }

        let result = await answer(request)
        try? store.write(
            KeyboardExchange(generatedAt: dateProvider.now, request: request, result: result)
        )
        return result
    }

    /// Runs one request.
    public func answer(_ request: KeyboardAssistantRequest) async -> KeyboardAssistantResult {
        do {
            let text: String
            switch request.operation {
            case .assistantQuery:
                text = try await commands.ask(request.inputText).message
            case .improve, .shorten, .grammar:
                text = try await engine.transformText(
                    instruction: Self.instruction(for: request.operation),
                    text: request.inputText
                )
            }
            return KeyboardAssistantResult(
                requestID: request.id,
                status: .completed,
                text: text,
                completedAt: dateProvider.now
            )
        } catch {
            // Section 22 and 28: one sentence, written here. Never a provider
            // diagnostic, a model name or an endpoint — this value is read by a
            // process the user's other apps can see the keyboard of.
            return KeyboardAssistantResult(
                requestID: request.id,
                status: .failed,
                error: Self.message(for: error),
                completedAt: dateProvider.now
            )
        }
    }

    /// What to ask the model for.
    ///
    /// Plain sentences, kept next to each other so the four operations cannot
    /// drift into meaning something different from their labels.
    static func instruction(for operation: KeyboardAssistantOperation) -> String {
        switch operation {
        case .improve:
            return "Rewrite this so it reads clearly and politely, keeping the meaning:"
        case .shorten:
            return "Rewrite this as briefly as possible without losing anything important:"
        case .grammar:
            return "Correct the spelling, punctuation and grammar. Change nothing else:"
        case .assistantQuery:
            return ""
        }
    }

    /// A request older than this is nobody's. Long enough that a slow launch
    /// still services one; short enough that yesterday's half-written sentence
    /// is not answered today.
    static let requestLifetime: TimeInterval = TimeSpan.minutes(2)

    private func isExpired(_ request: KeyboardAssistantRequest) -> Bool {
        dateProvider.now.timeIntervalSince(request.createdAt) > Self.requestLifetime
    }

    private static func message(for error: any Error) -> String {
        if let command = error as? AssistantCommandError { return command.message }
        return "Assistant unavailable"
    }
}
