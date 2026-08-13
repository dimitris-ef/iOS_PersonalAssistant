import AssistantAI
import AssistantDomain
import AssistantTools
import Foundation

/// Renders application state into the text a provider sees.
///
/// This is the only place that decides what a model is told. Nothing here is
/// provider-specific: a local model and a remote API get the same brief, so
/// switching between them does not change the assistant's character.
public struct SystemPromptBuilder: Sendable {
    public init() {}

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

        if !context.relevantMemories.isEmpty {
            let lines = context.relevantMemories.map { "- (\($0.kind.rawValue)) \($0.content)" }
            sections.append("# What you remember about this person\n" + lines.joined(separator: "\n"))
        }

        if !context.outstandingTasks.isEmpty {
            let lines = context.outstandingTasks.map { task -> String in
                let when = task.timing.anchorDate.map { " — \(Self.isoFormatter.string(from: $0))" } ?? ""
                return "- [\(task.status.rawValue)] \(task.title)\(when) (id: \(task.id))"
            }
            sections.append("# Open tasks\n" + lines.joined(separator: "\n"))
        }

        if !context.upcomingEvents.isEmpty {
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
