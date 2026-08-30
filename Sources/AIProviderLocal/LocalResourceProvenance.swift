import AssistantAI
import AssistantDomain
import Foundation

/// Where an identifier for an *existing* thing is allowed to come from.
///
/// ## The failure this prevents
///
/// A model asked to change something needs the identifier of the thing to
/// change. A model that does not have one, and has been shown a schema saying
/// the field is a UUID, will produce a UUID — a well-formed, plausible,
/// completely invented one. Nothing downstream can tell it apart from a real
/// one by looking at it: the type is right, the format is right, and the only
/// thing wrong with it is that it does not refer to anything.
///
/// The observed case named `updateCalendarEvent` with an invented `eventID` in
/// response to "remind me in ten minutes", which is a request to *create*
/// something and involves no existing event at all.
///
/// ## The rule
///
/// Section 14 and 16: an identifier for an existing resource is trusted only if
/// the application has already produced it. In practice that means a prior
/// `AIToolResult` payload in this same conversation — a search that found the
/// event, or a create that made it. Anything else, however well-formed, is
/// rejected before execution.
///
/// ## What this is not
///
/// Section 29. `ToolCallID` — the handle the app mints to track an invocation —
/// is not a resource identifier and never satisfies this check. They are
/// different things that happen to be the same shape, which is precisely why
/// they get confused; the trusted set is built only from result *payloads*, and
/// a call id never enters it.
public struct LocalResourceProvenance: Hashable, Sendable {

    /// Every identifier the application itself has handed back this turn.
    public private(set) var trusted: Set<String>

    public init(trusted: Set<String> = []) {
        self.trusted = trusted
    }

    /// Harvests identifiers from the conversation's tool results.
    ///
    /// Only `.tool` messages carrying a real `AIToolResult` count. An assistant
    /// message's own `toolCalls` are *not* harvested even though they are right
    /// there and would make this look more permissive: those arguments are what
    /// the model said, and treating them as trusted would make a fabricated id
    /// trusted on its second appearance.
    public static func harvested(from messages: [AIMessage]) -> LocalResourceProvenance {
        var trusted: Set<String> = []
        for message in messages {
            guard let result = message.toolResult else { continue }
            // A failed or skipped call produced no resource, so whatever it
            // echoes back is not a handle to anything.
            //
            // `didAct` rather than `== .succeeded`, deliberately: it is the
            // domain's own notion of "the intent was carried out", and it
            // includes the simulated case. A mock-platform build really does
            // record the action and mint an identifier for it, and excluding
            // those would make find-then-update fail in exactly the
            // configuration used to develop it.
            guard result.status.didAct else { continue }
            for (key, value) in result.payload where Self.looksLikeIdentifierKey(key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                trusted.insert(trimmed.lowercased())
            }
        }
        return LocalResourceProvenance(trusted: trusted)
    }

    /// Whether a value came from the application.
    public func isTrusted(_ identifier: String) -> Bool {
        trusted.contains(identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Payload keys that name a resource rather than describe one.
    ///
    /// Suffix-based rather than an exhaustive list, so a tool added later whose
    /// result carries a `routineID` is covered without anybody remembering to
    /// come back here.
    static func looksLikeIdentifierKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.hasSuffix("id") || lowered.hasSuffix("identifier")
    }
}

/// Which arguments of which tools point at something that must already exist.
///
/// Derived from `ToolKind` rather than from a hand-kept list of strings, so a
/// tool that is added to the domain and forgotten here fails closed on the
/// name lookup instead of silently skipping the check.
public enum LocalResourceReference {

    /// The argument names that must refer to an existing resource, per tool.
    ///
    /// Creates appear nowhere in this table, which is the point: a create has
    /// no existing resource to refer to, so there is nothing for a model to
    /// invent (section 13).
    public static func requiredExistingIdentifiers(for tool: String) -> [String] {
        guard let kind = ToolKind(rawValue: tool) else { return [] }
        switch kind {
        case .updateCalendarEvent, .deleteCalendarEvent:
            return ["eventID"]
        case .completeReminder:
            return ["reminderID"]
        case .updateAlarm, .cancelAlarm:
            return ["alarmID"]
        case .updateMemory:
            return ["memoryID"]
        case .completeTask, .startTask:
            return ["taskID"]
        case .addTaskDependency:
            return ["prerequisiteTaskID", "dependentTaskID"]
        case .createCalendarEvent, .createReminder, .createAlarm,
             .scheduleNotification, .storeMemory, .createTask, .createFollowUp,
             .getUpcomingSchedule, .createRoutine, .askClarification:
            return []
        }
    }
}

/// Why a proposed call was not allowed to reach validation.
public enum LocalToolProvenanceFailure: Hashable, Sendable, CustomStringConvertible {
    /// The call needs an existing resource and named one that nothing produced.
    case fabricatedIdentifier(tool: String, argument: String)
    /// The call needs an existing resource and gave no identifier at all.
    case missingIdentifier(tool: String, argument: String)

    public var description: String {
        switch self {
        case .fabricatedIdentifier(let tool, let argument):
            return "\(tool) was given a \(argument) that no tool result produced"
        case .missingIdentifier(let tool, let argument):
            return "\(tool) requires \(argument) and none was supplied"
        }
    }

    public var symbol: String {
        switch self {
        case .fabricatedIdentifier: return "fabricatedIdentifier"
        case .missingIdentifier: return "missingIdentifier"
        }
    }
}

extension LocalResourceProvenance {

    /// Checks one proposed call.
    ///
    /// Returns nil when the call may proceed — which still means only that it
    /// reaches the existing decoder, validator, authorizer and confirmation
    /// (section 28). Nothing here approves anything.
    public func check(_ call: AIToolCall) -> LocalToolProvenanceFailure? {
        let required = LocalResourceReference.requiredExistingIdentifiers(for: call.name)
        guard !required.isEmpty else { return nil }
        guard let arguments = call.arguments.objectValue else { return nil }

        for argument in required {
            guard
                let value = arguments[argument]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                // Section 17: report it, do not ask the model to make one up.
                // The engine's own find-then-update flow is how this is meant
                // to be satisfied.
                return .missingIdentifier(tool: call.name, argument: argument)
            }
            guard isTrusted(value) else {
                return .fabricatedIdentifier(tool: call.name, argument: argument)
            }
        }
        return nil
    }

    /// Splits proposed calls into those that may proceed and those that may not.
    public func partition(
        _ calls: [AIToolCall]
    ) -> (allowed: [AIToolCall], rejected: [(AIToolCall, LocalToolProvenanceFailure)]) {
        var allowed: [AIToolCall] = []
        var rejected: [(AIToolCall, LocalToolProvenanceFailure)] = []
        for call in calls {
            if let failure = check(call) {
                rejected.append((call, failure))
            } else {
                allowed.append(call)
            }
        }
        return (allowed, rejected)
    }
}
