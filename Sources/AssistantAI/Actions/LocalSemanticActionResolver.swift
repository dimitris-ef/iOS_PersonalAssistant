import AssistantDomain
import Foundation

/// One thing the app found when it went looking for what the user meant.
public struct LocalResourceCandidate: Hashable, Sendable {
    /// The real identifier, from the app's own store. Never model-supplied.
    public var identifier: String
    /// What to call it when asking the user which one they meant.
    public var label: String

    public init(identifier: String, label: String) {
        self.identifier = identifier
        self.label = label
    }
}

/// The result of looking up a described thing.
public enum LocalResourceMatch: Hashable, Sendable {
    case none
    case one(LocalResourceCandidate)
    case ambiguous([LocalResourceCandidate])
}

/// Finds the existing thing a description refers to.
///
/// Sections 16 to 20. The whole point is that identifiers enter the pipeline
/// here and only here — from the app's own store, in response to a human
/// description. A model that says "my dentist appointment" cannot cause a
/// lookup to return something that does not exist; a model that says
/// `eventID: 4F2C…` cannot say it at all, because the protocol has no field for
/// it.
public protocol LocalSemanticResourceResolving: Sendable {
    func resolveTask(matching description: String) async -> LocalResourceMatch
    func resolveCalendarEvent(matching description: String) async -> LocalResourceMatch
}

/// Why the app has to ask before it can act.
public enum LocalSemanticClarificationReason: String, Hashable, Sendable {
    case timeNotUnderstood
    case timeInThePast
    case noMatchingResource
    case ambiguousResource
    case lookupUnavailable
}

/// What resolution produced.
///
/// Section 106. Three outcomes, and none of them is "act on a guess". A
/// question the user can answer is a better result than a reminder set to the
/// wrong day, because they find out about the wrong day by missing the thing.
public enum LocalSemanticResolution: Hashable, Sendable {
    /// A real call, ready for the existing decoder, validator, authorizer and
    /// confirmation flow. Nothing here skips any of them.
    case resolved(AIToolCall)
    case needsClarification(question: String, reason: LocalSemanticClarificationReason)
    case failed(reason: String)

    public var toolCall: AIToolCall? {
        if case .resolved(let call) = self { return call }
        return nil
    }

    /// For the diagnostic log (section 65).
    public var symbol: String {
        switch self {
        case .resolved: return "resolved"
        case .needsClarification(_, let reason): return "needsClarification:\(reason.rawValue)"
        case .failed: return "failed"
        }
    }
}

/// Turns a semantic action into a tool call the app can validate.
///
/// A protocol so the action path can be assembled by the composition root
/// without `AssistantCore` naming a concrete resolver — and so a test can
/// substitute one. There is exactly one production implementation
/// (``LocalSemanticActionResolver``), and it is deterministic.
public protocol SemanticActionResolving: Sendable {
    func resolve(_ action: LocalSemanticAction) async -> LocalSemanticResolution
}

/// Turns a validated semantic action into a real tool call.
///
/// ## Where implementation details come from
///
/// Every value the device report showed being fabricated is decided here
/// instead:
///
/// | Fabricated on device | Decided here by |
/// | --- | --- |
/// | `relatedTaskID` | nothing — the field is not sent at all |
/// | a 2023 due date | `LocalTimeExpressionResolver` and the real clock |
/// | an invented list name | omitted, so the platform's default list is used |
/// | invented notes | omitted; the user did not dictate notes |
/// | an event id for an update | a lookup against the app's own store |
///
/// The resolver is the only component in the local path that knows what
/// `createReminder` is called or which of its arguments exist. The model never
/// sees any of it.
///
/// ## What it deliberately does not do
///
/// It does not execute anything, and it does not shortcut anything. The
/// `AIToolCall` it returns goes into the existing pipeline — schema decoding,
/// validation, provenance, authorization, confirmation, `PlatformServices` —
/// exactly as a call from any other provider would. This type narrows what can
/// be *asked for*; it removes none of the checks on what is then done.
public struct LocalSemanticActionResolver: SemanticActionResolving, Sendable {

    public let dateProvider: any DateProvider
    public let resources: (any LocalSemanticResourceResolving)?

    private let time: LocalTimeExpressionResolver

    public init(
        dateProvider: any DateProvider,
        resources: (any LocalSemanticResourceResolving)? = nil
    ) {
        self.dateProvider = dateProvider
        self.resources = resources
        self.time = LocalTimeExpressionResolver(dateProvider: dateProvider)
    }

    /// The default kind for a fact the user asked to be remembered.
    ///
    /// `storeMemory` requires one and the protocol does not offer it, so the app
    /// picks — deterministically, and the most neutral of the six. A model
    /// guessing between `routine`, `preference` and `person` would be inventing
    /// a classification the user never gave.
    static let defaultMemoryKind = MemoryKind.fact

    /// Resolves one validated action into a call, a question, or nothing.
    ///
    /// An event whose length nobody stated is left without an `end`, so the
    /// tool's own default applies — one default, in one place.
    public func resolve(_ action: LocalSemanticAction) async -> LocalSemanticResolution {
        switch action.intent {
        case .chat:
            return .failed(reason: "chat is not an action")
        case .reminderCreate:
            return resolveReminder(action)
        case .memoryStore:
            return resolveMemory(action)
        case .taskCreate:
            return resolveTaskCreate(action)
        case .taskComplete:
            return await resolveTaskComplete(action)
        case .calendarCreate:
            return resolveCalendarCreate(action)
        case .calendarUpdate:
            return await resolveCalendarUpdate(action)
        }
    }

    // MARK: Create

    private func resolveReminder(_ action: LocalSemanticAction) -> LocalSemanticResolution {
        guard let title = action[.title], let expression = action[.timeExpression] else {
            return .failed(reason: "reminder is missing a required field")
        }
        switch time.resolve(expression) {
        case .resolved(let resolved):
            // Exactly two arguments. No notes, no list, no related task — the
            // three things the model invented on the device, none of which the
            // user said.
            return .resolved(
                AIToolCall(
                    name: ToolKind.createReminder.rawValue,
                    arguments: .object([
                        "title": .string(title),
                        "dueDate": .string(iso(resolved.date)),
                    ])
                )
            )
        case .notUnderstood(let reason):
            return clarifyTime(expression: expression, reason: reason)
        }
    }

    private func resolveMemory(_ action: LocalSemanticAction) -> LocalSemanticResolution {
        guard let content = action[.content] else {
            return .failed(reason: "memory is missing a required field")
        }
        return .resolved(
            AIToolCall(
                name: ToolKind.storeMemory.rawValue,
                arguments: .object([
                    "content": .string(content),
                    "kind": .string(Self.defaultMemoryKind.rawValue),
                ])
            )
        )
    }

    private func resolveTaskCreate(_ action: LocalSemanticAction) -> LocalSemanticResolution {
        guard let title = action[.title] else {
            return .failed(reason: "task is missing a required field")
        }
        var arguments: [String: JSONValue] = ["title": .string(title)]
        if let expression = action[.timeExpression] {
            switch time.resolve(expression) {
            case .resolved(let resolved):
                arguments["dueDate"] = .string(iso(resolved.date))
            case .notUnderstood(let reason):
                // The time was optional to *supply*, but once supplied it is not
                // optional to understand: silently dropping it would create a
                // task the user believes has a deadline.
                return clarifyTime(expression: expression, reason: reason)
            }
        }
        return .resolved(
            AIToolCall(name: ToolKind.createTask.rawValue, arguments: .object(arguments))
        )
    }

    private func resolveCalendarCreate(_ action: LocalSemanticAction) -> LocalSemanticResolution {
        guard let title = action[.title], let expression = action[.timeExpression] else {
            return .failed(reason: "event is missing a required field")
        }
        let start: LocalResolvedTime
        switch time.resolve(expression) {
        case .resolved(let resolved):
            start = resolved
        case .notUnderstood(let reason):
            return clarifyTime(expression: expression, reason: reason)
        }

        var arguments: [String: JSONValue] = [
            "title": .string(title),
            "start": .string(iso(start.date)),
        ]
        if let durationExpression = action[.durationExpression],
            let duration = time.resolveDuration(durationExpression) {
            arguments["end"] = .string(iso(start.date.addingTimeInterval(duration)))
        }
        if let location = action[.locationExpression] {
            arguments["location"] = .string(location)
        }
        return .resolved(
            AIToolCall(
                name: ToolKind.createCalendarEvent.rawValue, arguments: .object(arguments)
            )
        )
    }

    // MARK: Existing things

    private func resolveTaskComplete(
        _ action: LocalSemanticAction
    ) async -> LocalSemanticResolution {
        guard let description = action[.targetDescription] else {
            return .failed(reason: "completion is missing a required field")
        }
        guard let resources else {
            return .needsClarification(
                question: "I can't look that up right now. Which one did you mean?",
                reason: .lookupUnavailable
            )
        }
        switch await resources.resolveTask(matching: description) {
        case .one(let candidate):
            return .resolved(
                AIToolCall(
                    name: ToolKind.completeTask.rawValue,
                    arguments: .object([
                        "taskID": .string(candidate.identifier),
                        // Section 44: the user said it was done. The tool's own
                        // guard still applies.
                        "confirmedByUser": .bool(true),
                    ])
                )
            )
        case .none:
            return .needsClarification(
                question: "I couldn't find a task matching \"\(description)\". "
                    + "What is it called?",
                reason: .noMatchingResource
            )
        case .ambiguous(let candidates):
            return .needsClarification(
                question: Self.chooseQuestion(candidates), reason: .ambiguousResource
            )
        }
    }

    private func resolveCalendarUpdate(
        _ action: LocalSemanticAction
    ) async -> LocalSemanticResolution {
        guard let description = action[.targetDescription] else {
            return .failed(reason: "update is missing a required field")
        }
        guard let resources else {
            return .needsClarification(
                question: "I can't look that up right now. Which event did you mean?",
                reason: .lookupUnavailable
            )
        }

        let match = await resources.resolveCalendarEvent(matching: description)
        let candidate: LocalResourceCandidate
        switch match {
        case .one(let found):
            candidate = found
        case .none:
            return .needsClarification(
                question: "I couldn't find an event matching \"\(description)\". "
                    + "What is it called?",
                reason: .noMatchingResource
            )
        case .ambiguous(let candidates):
            return .needsClarification(
                question: Self.chooseQuestion(candidates), reason: .ambiguousResource
            )
        }

        // The identifier comes from the lookup above and from nowhere else,
        // which is what makes the fabricated-UUID failure structurally
        // impossible rather than merely caught.
        var arguments: [String: JSONValue] = ["eventID": .string(candidate.identifier)]

        if let expression = action.requestedChanges[.timeExpression] {
            switch time.resolve(expression) {
            case .resolved(let resolved):
                arguments["start"] = .string(iso(resolved.date))
                if let durationExpression = action.requestedChanges[.durationExpression],
                    let duration = time.resolveDuration(durationExpression) {
                    arguments["end"] = .string(iso(resolved.date.addingTimeInterval(duration)))
                }
            case .notUnderstood(let reason):
                return clarifyTime(expression: expression, reason: reason)
            }
        }
        if let title = action.requestedChanges[.title] {
            arguments["title"] = .string(title)
        }
        if let location = action.requestedChanges[.locationExpression] {
            arguments["location"] = .string(location)
        }

        guard arguments.count > 1 else {
            return .failed(reason: "nothing to change")
        }
        return .resolved(
            AIToolCall(
                name: ToolKind.updateCalendarEvent.rawValue, arguments: .object(arguments)
            )
        )
    }

    // MARK: Helpers

    private func clarifyTime(expression: String, reason: String) -> LocalSemanticResolution {
        let past = reason.contains("passed")
        return .needsClarification(
            question: past
                ? "That time has already gone by. When would you like it instead?"
                : "When would you like that? I couldn't work out \"\(expression)\".",
            reason: past ? .timeInThePast : .timeNotUnderstood
        )
    }

    static func chooseQuestion(_ candidates: [LocalResourceCandidate]) -> String {
        let names = candidates.prefix(3).map(\.label).joined(separator: ", ")
        return "I found more than one: \(names). Which one did you mean?"
    }

    /// Tool arguments carry dates as ISO-8601, matching `JSONCoding`.
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = dateProvider.calendar.timeZone
        return formatter.string(from: date)
    }
}
