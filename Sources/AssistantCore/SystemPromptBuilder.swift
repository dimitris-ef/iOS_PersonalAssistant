import AssistantAI
import AssistantDomain
import AssistantTools
import Foundation
import PersonalMemory

/// Renders application state into the text a provider sees.
///
/// This is the only place that decides what a model is told. Nothing here is
/// provider-specific: a local model and a remote API get the same brief, so
/// switching between them does not change the assistant's character.
public struct SystemPromptBuilder: Sendable {
    private let memoryFormatter: MemoryContextFormatter

    public init(memoryFormatter: MemoryContextFormatter = MemoryContextFormatter()) {
        self.memoryFormatter = memoryFormatter
    }

    public func systemPrompt(for context: AssistantContext) -> String {
        var sections: [String] = []

        sections.append(
            """
            You are a personal assistant for someone who relies on you for executive-function \
            support. Be concise and concrete. Confirm what you have done in one or two sentences.

            Never claim to have done something unless you requested it through a tool.
            """
        )

        sections.append(
            """
            # Current time
            \(Self.isoFormatter.string(from: context.now)) (time zone: \(context.profile.timeZoneIdentifier))
            """
        )

        sections.append(profileSection(context))

        // Rendered by the formatter so the wording is provider-neutral and in
        // one place — and so confidence, salience and identifiers stay out of
        // the prompt. Those decide what gets selected; the model gets facts.
        if let section = memoryFormatter.section(for: context.relevantMemories) {
            sections.append(section)
        }

        if !context.outstandingTasks.isEmpty {
            let lines = context.outstandingTasks.map { task -> String in
                let when = task.timing.anchorDate.map { " — \(Self.isoFormatter.string(from: $0))" } ?? ""
                return "- [\(task.status.rawValue)] \(task.title)\(when) (id: \(task.id))"
            }
            sections.append("# Open tasks\n" + lines.joined(separator: "\n"))
        }

        if !context.calendarIsReadable {
            // Stated explicitly, because the alternative is a model that reads
            // an absent calendar section as an empty diary and says "you're
            // free then" to someone who is not.
            sections.append(
                """
                # Upcoming calendar
                Unavailable — this app cannot read the calendar right now. Do not assume any \
                time is free, and say that you cannot see their schedule if it matters to \
                the answer.
                """
            )
        } else if !context.upcomingEvents.isEmpty {
            let lines = context.upcomingEvents.map { event in
                "- \(event.title) — \(Self.isoFormatter.string(from: event.start)) (id: \(event.id))"
            }
            sections.append("# Upcoming calendar\n" + lines.joined(separator: "\n"))
        }

        sections.append(
            """
            # How to act
            Use tools for anything that changes state. Do not describe an action in prose \
            instead of calling the tool for it.

            When the person mentions an appointment or commitment, create the calendar event \
            and let the app build the supporting reminders — you do not need to schedule each \
            reminder yourself unless they asked for something specific.

            Dismissing a reminder is not the same as finishing a task. Only call \
            \(ToolKind.completeTask.rawValue) when the person has actually confirmed it is done.

            Something that repeats is a routine, not a task. When they say every, each, \
            daily, weekly, or name a day that comes round again, call \
            \(ToolKind.createRoutine.rawValue) once — the app generates each occurrence \
            itself. Do not create one task per week.

            When one thing has to happen before another, say so with \
            \(ToolKind.addTaskDependency.rawValue) rather than folding it into the wording \
            of a reminder. The app then stops chasing the blocked one until it can \
            actually be done.

            When someone is stuck starting, call \(ToolKind.startTask.rawValue). It gives \
            them one concrete first step and marks the task in progress. It does not \
            complete anything, and encouragement is not a substitute for it.
            """
        )

        sections.append(
            """
            # Requests with several parts
            One message can need several actions. Ask for all of them — either \
            together in one turn, or one at a time when a later action depends on \
            what an earlier one produced.

            After each action you will be shown what actually happened, including \
            failures. Read those results before deciding what to do next, and \
            describe only what they say. If an action failed, say so plainly and \
            carry on with the parts that can still be done; do not repeat an action \
            that already succeeded, and do not try again something that was refused \
            because of permissions or settings.

            Ask a question with \(ToolKind.askClarification.rawValue) only when acting \
            would otherwise be a guess between real alternatives — several events \
            that all match what they said, for example. Do not ask about reminder \
            timing, how far ahead to warn, or whether to follow up: this app decides \
            those, and asking makes the person do work they came here to avoid.
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private func profileSection(_ context: AssistantContext) -> String {
        var lines: [String] = ["# About this person"]
        if let name = context.profile.displayName {
            lines.append("- Name: \(name)")
        }
        lines.append(
            "- Usually needs \(Int(context.profile.defaultPreparationDuration / 60)) minutes to get ready"
        )
        if let wake = context.profile.wakeTime {
            lines.append("- Usually wakes at \(wake)")
        }
        if let quiet = context.profile.quietHours {
            lines.append("- Quiet hours: \(quiet.start)–\(quiet.end)")
        }
        return lines.joined(separator: "\n")
    }

    /// Maps the persisted transcript into provider messages.
    public func messages(for context: AssistantContext) -> [AIMessage] {
        context.conversation
            .recentMessages(limit: context.settings.conversationContextLimit)
            .map { message in
                switch message.role {
                case .user: return AIMessage(role: .user, content: message.text)
                case .assistant: return AIMessage(role: .assistant, content: message.text)
                case .system: return AIMessage(role: .system, content: message.text)
                }
            }
    }

    /// The tool catalogue, in the AI layer's vocabulary.
    public func toolSchemas() -> [AIToolSchema] {
        ToolCatalog.all.map { specification in
            AIToolSchema(
                name: specification.name,
                description: specification.summary,
                parameters: specification.parameters
            )
        }
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
