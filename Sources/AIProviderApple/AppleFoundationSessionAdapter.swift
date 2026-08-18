#if canImport(FoundationModels)

import AssistantAI
import AssistantDomain
import Foundation
import FoundationModels

/// Turns one provider-neutral `AIRequest` into a Foundation Models session.
///
/// ## Why a session per request
///
/// Apple's `LanguageModelSession` can be kept alive across turns, and for an
/// app whose chat *is* the session that is the natural design. It is the wrong
/// one here.
///
/// `AssistantEngine` already owns the transcript. It assembles the messages for
/// every turn from the `ConversationRepository`, trims them to the user's
/// `conversationContextLimit`, and re-sends the whole list on each round — that
/// is the contract every provider is written to, and the remote provider works
/// the same way. A long-lived session would hold a *second* copy of the
/// conversation, which would then have to be kept in step with the first
/// through provider switches, app relaunches, message edits and context
/// trimming. Two sources of truth for the same history, and the persisted one
/// would be the one that lost.
///
/// So the session is rebuilt from the request each time and thrown away after.
/// It is ephemeral infrastructure; the repository is the record. The cost is
/// re-sending history the framework has already seen, which is what the
/// engine's own trimming keeps bounded.
///
/// Nothing here reads a repository, and nothing here retrieves memories. The
/// relevant memories are already inside `request.systemPrompt`, put there by
/// `ContextAssembler` and `MemoryRetrievalService` — the same text, from the
/// same ranking, that the remote provider receives.
@available(iOS 26.0, macOS 26.0, *)
struct AppleFoundationSessionAdapter {

    /// What the model should be asked, and the history it should already know.
    struct PreparedRequest {
        var transcript: Transcript
        var prompt: Prompt
        var options: GenerationOptions
    }

    /// Sent when the engine comes back for a closing reply.
    ///
    /// Foundation Models needs *a* prompt for every `respond` call, but on the
    /// second round the last thing in the conversation is a set of tool
    /// results, not a question. Rather than replay the user's original message
    /// — which would invite the model to propose the same actions again — this
    /// asks for the one thing still missing.
    static let continuationPrompt = """
        The requested actions have now been carried out by the app and their \
        results are above. Reply to the person in one or two sentences, saying \
        only what actually happened.
        """

    /// Builds the transcript, the prompt and the options for one request.
    static func prepare(
        _ request: AIRequest,
        toolDefinitions: [Transcript.ToolDefinition]
    ) throws -> PreparedRequest {
        var entries: [Transcript.Entry] = []

        // The app's own system prompt, unchanged. There is no Apple-specific
        // assistant personality: the brief that shapes the remote model shapes
        // this one, so switching provider does not change who the assistant is.
        entries.append(
            .instructions(
                Transcript.Instructions(
                    id: UUID().uuidString,
                    segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: request.systemPrompt))],
                    toolDefinitions: toolDefinitions
                )
            )
        )

        // The trailing user message is the prompt; everything before it is
        // history the session should already be holding.
        var history = request.messages
        var prompt: Prompt
        if let last = history.last, last.role == .user {
            history.removeLast()
            prompt = Prompt(last.content)
        } else {
            prompt = Prompt(continuationPrompt)
        }

        entries.append(contentsOf: try transcriptEntries(for: history))

        var options = GenerationOptions()
        // Assigned rather than passed to an initialiser on purpose: both
        // `GenerationOptions` initialisers take every argument with a default,
        // so a call naming only these two is ambiguous between them.
        options.temperature = request.options.temperature
        options.maximumResponseTokens = request.options.maximumOutputTokens

        return PreparedRequest(
            transcript: Transcript(entries: entries),
            prompt: prompt,
            options: options
        )
    }

    /// Provider-neutral messages as transcript entries.
    ///
    /// The mapping keeps the *meaning* of each message rather than its shape:
    /// an assistant turn that proposed tools becomes a response entry plus a
    /// tool-calls entry, because that is how the framework records the same
    /// event. The stored `Message` type is untouched — nothing in the domain
    /// knows this representation exists.
    private static func transcriptEntries(for messages: [AIMessage]) throws -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        // Tool results arrive as separate messages identified only by call id,
        // so the name has to be carried forward from the call that produced it.
        var toolNamesByCallID: [ToolCallID: String] = [:]

        for message in messages {
            switch message.role {
            case .user:
                entries.append(
                    .prompt(
                        Transcript.Prompt(
                            id: UUID().uuidString,
                            segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: message.content))]
                        )
                    )
                )

            case .system:
                // A system message mid-conversation is rare — the standing
                // brief is the instructions entry. Carried as a prompt so it
                // cannot be silently dropped, which is the failure that would
                // be hardest to notice.
                entries.append(
                    .prompt(
                        Transcript.Prompt(
                            id: UUID().uuidString,
                            segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: message.content))]
                        )
                    )
                )

            case .assistant:
                if !message.content.isEmpty {
                    entries.append(
                        .response(
                            Transcript.Response(
                                id: UUID().uuidString,
                                assetIDs: [],
                                segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: message.content))]
                            )
                        )
                    )
                }

                guard !message.toolCalls.isEmpty else { continue }

                var calls: [Transcript.ToolCall] = []
                for call in message.toolCalls {
                    toolNamesByCallID[call.id] = call.name
                    calls.append(
                        Transcript.ToolCall(
                            // The application's own call id on both sides, so
                            // a call and its output identify each other.
                            id: call.id.rawValue.uuidString,
                            toolName: call.name,
                            arguments: try AppleGenerationSchemaBridge.generatedContent(from: call.arguments)
                        )
                    )
                }
                entries.append(.toolCalls(Transcript.ToolCalls(id: UUID().uuidString, calls)))

            case .tool:
                // What the app actually did — including, in as many words, when
                // the work was only simulated. The engine writes that text; it
                // is passed through unedited so the model cannot be told the
                // phone did something it did not.
                //
                // TODO-DEVICE: the output carries the same id as the call it
                // answers, on the assumption that is how the framework pairs
                // them. Entry order preserves the pairing either way, but
                // whether the model reads them as connected has not been
                // observed on a real device.
                guard let callID = message.toolCallID else { continue }
                entries.append(
                    .toolOutput(
                        Transcript.ToolOutput(
                            id: callID.rawValue.uuidString,
                            toolName: toolNamesByCallID[callID] ?? "",
                            segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: message.content))]
                        )
                    )
                )
            }
        }

        return entries
    }
}

#endif
