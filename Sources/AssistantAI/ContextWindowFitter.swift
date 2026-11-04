import Foundation

/// Drops the oldest history from a request so it fits a model's context window.
///
/// ## Why this exists
///
/// Apple's on-device model reads about 4,096 tokens at once — the standing
/// instructions, the tool definitions, the history, the question *and* the
/// reply all share that. The engine bounds history by message count, which a
/// cloud model never notices and the on-device model hits within a few turns:
/// build 20 answered "That conversation is too long for the on-device model"
/// after a handful of messages, in an app that had no way to start another.
///
/// ## What it keeps, and what it drops
///
/// The current turn is never touched: the last user message and everything
/// after it (the tool calls and results of a continuation round). Without
/// those there is nothing to answer. Older history goes from the front, and
/// only ever at a user message, so a tool call is never separated from its
/// result. Nothing is deleted from the conversation — it simply is not re-read.
///
/// ## The estimate
///
/// One token per three bytes of UTF-8. Deliberately pessimistic: English runs
/// nearer four characters a token, and underestimating costs a failed reply
/// while overestimating costs a line of old conversation.
public enum ContextWindowFitter {

    /// Room kept free for the framework's own formatting.
    public static let defaultSafetyMarginTokens = 256

    /// What a reply is assumed to need when the request does not say.
    public static let defaultReplyTokens = 512

    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    /// The request, with the oldest history removed until it fits.
    public static func fit(
        _ request: AIRequest,
        windowTokens: Int,
        safetyMarginTokens: Int = defaultSafetyMarginTokens
    ) -> AIRequest {
        let current = currentTurnStart(in: request.messages)
        var budget = windowTokens - fixedTokens(of: request, safetyMarginTokens: safetyMarginTokens)
        // Walk back from the current turn, keeping whole user-led exchanges
        // while they fit.
        var keepFrom = current
        var index = current - 1
        var pending = 0
        while index >= 0 {
            pending += cost(of: request.messages[index])
            if request.messages[index].role == .user {
                guard pending <= budget else { break }
                budget -= pending
                pending = 0
                keepFrom = index
            }
            index -= 1
        }

        guard keepFrom > 0 else { return request }
        var fitted = request
        fitted.messages = Array(request.messages[keepFrom...])
        return fitted
    }

    /// The request, fitted — leaving the tools out when they would crowd out
    /// the conversation.
    ///
    /// Build 21: the descriptions of the app's nineteen tools, with the
    /// instructions, open tasks and upcoming events, came to more than Apple's
    /// whole window, so even a brand-new chat answered "too long". Tools are
    /// kept only if, with them, at least `minimumHistoryTokens` remain for the
    /// conversation; otherwise they are dropped and `noToolsNote` is added to
    /// the instructions, so the model says it cannot act rather than pretending
    /// it has. Requests to act are normally routed to the action model before
    /// they reach a chat model at all, so this costs little.
    public static func fitDroppingToolsIfNeeded(
        _ request: AIRequest,
        windowTokens: Int,
        minimumHistoryTokens: Int = 1_000,
        noToolsNote: String = defaultNoToolsNote,
        safetyMarginTokens: Int = defaultSafetyMarginTokens
    ) -> (request: AIRequest, droppedTools: Bool) {
        guard !request.tools.isEmpty else {
            return (fit(request, windowTokens: windowTokens, safetyMarginTokens: safetyMarginTokens), false)
        }
        // A continuation round already holds tool calls and results; taking
        // the definitions away from under them would leave a transcript
        // naming tools that do not exist. The decision is made on the first
        // round of a turn, never halfway through one.
        let current = currentTurnStart(in: request.messages)
        let isContinuation = request.messages[current...].contains {
            !$0.toolCalls.isEmpty || $0.role == .tool
        }
        let room = windowTokens - fixedTokens(of: request, safetyMarginTokens: safetyMarginTokens)
        if isContinuation || room >= minimumHistoryTokens {
            return (fit(request, windowTokens: windowTokens, safetyMarginTokens: safetyMarginTokens), false)
        }
        var withoutTools = request
        withoutTools.tools = []
        withoutTools.systemPrompt += "\n\n" + noToolsNote
        return (fit(withoutTools, windowTokens: windowTokens, safetyMarginTokens: safetyMarginTokens), true)
    }

    /// Said to a chat model that has been left without tools.
    public static let defaultNoToolsNote = """
        # In this conversation
        You cannot use tools here, so you cannot create, change or complete \
        reminders, tasks, calendar events or memories, whatever the instructions \
        above say. Never say you have done one. If the person asks for one, tell \
        them to ask directly — for example "remind me at 6 to call mum" or "move \
        my dentist appointment to Friday at 5" — or to use Quick Task, the \
        lightning button at the top of the screen.
        """

    /// Everything but the older history: instructions, tools, the current
    /// turn, the reply and the margin.
    static func fixedTokens(of request: AIRequest, safetyMarginTokens: Int) -> Int {
        let current = currentTurnStart(in: request.messages)
        return estimatedTokens(request.systemPrompt)
            + estimatedTokens(encoded(request.tools))
            + (request.options.maximumOutputTokens ?? defaultReplyTokens)
            + safetyMarginTokens
            + request.messages[current...].reduce(0) { $0 + cost(of: $1) }
    }

    /// Where the turn being answered begins: the last user message.
    static func currentTurnStart(in messages: [AIMessage]) -> Int {
        messages.lastIndex { $0.role == .user } ?? 0
    }

    static func cost(of message: AIMessage) -> Int {
        var tokens = estimatedTokens(message.content) + 4
        if !message.toolCalls.isEmpty {
            tokens += estimatedTokens(encoded(message.toolCalls))
        }
        return tokens
    }

    private static func encoded<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
