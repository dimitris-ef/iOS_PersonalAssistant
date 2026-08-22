import Foundation

/// The prompt shape a set of weights expects.
///
/// ## Why this is not one format
///
/// Section 39. A model is trained on a specific arrangement of role markers,
/// and giving it a different one is not a stylistic choice — the weights have
/// never seen the tokens you are feeding them, and the output degrades into
/// something that looks like a language model having a bad day. A Qwen model
/// wants `<|im_start|>`, Llama 3 wants `<|start_header_id|>`, Gemma wants
/// `<start_of_turn>`, and Mistral wants `[INST]`.
///
/// ## Why `modelDefault` is the default
///
/// Because the file usually knows. GGUF carries `tokenizer.chat_template`, and
/// llama.cpp can apply it — which is right by construction in a way that a
/// table in this file can never be, since the table was written before the
/// model existed. Everything below is the fallback for a file that has no
/// template, and for builds with no llama.cpp linked at all.
public enum LocalChatTemplate: String, Hashable, Codable, Sendable, CaseIterable {
    /// Use the template inside the model file; fall back to ``chatML`` if it
    /// has none.
    case modelDefault
    /// `<|im_start|>role\n…<|im_end|>` — Qwen, Yi, and most fine-tunes.
    case chatML
    /// Llama 3's header blocks.
    case llama3
    /// `<start_of_turn>user … <end_of_turn>`.
    case gemma
    /// `[INST] … [/INST]`, which has no system role of its own.
    case mistral
    /// `<|system|> … <|end|>`.
    case phi3
    /// Labelled plain text. Not a real template — the last resort for a model
    /// whose expected format is unknown.
    case plain

    public var displayName: String {
        switch self {
        case .modelDefault: return "From the model file"
        case .chatML: return "ChatML"
        case .llama3: return "Llama 3"
        case .gemma: return "Gemma"
        case .mistral: return "Mistral"
        case .phi3: return "Phi-3"
        case .plain: return "Plain text"
        }
    }

    /// What to render when the file has no template of its own.
    var concreteFallback: LocalChatTemplate {
        self == .modelDefault ? .chatML : self
    }

    /// Renders turns into the prompt string the weights expect.
    ///
    /// Ends with the opening of an assistant turn, so the model continues
    /// rather than starting a fresh conversation.
    public func render(_ turns: [LocalChatTurn]) -> String {
        switch concreteFallback {
        case .chatML, .modelDefault:
            var out = ""
            for turn in turns {
                out += "<|im_start|>\(turn.role)\n\(turn.content)<|im_end|>\n"
            }
            return out + "<|im_start|>assistant\n"

        case .llama3:
            var out = "<|begin_of_text|>"
            for turn in turns {
                out += "<|start_header_id|>\(turn.role)<|end_header_id|>\n\n"
                out += "\(turn.content)<|eot_id|>"
            }
            return out + "<|start_header_id|>assistant<|end_header_id|>\n\n"

        case .gemma:
            // Gemma has no system role. The system prompt is folded into the
            // first user turn rather than dropped — losing it would remove
            // every instruction the assistant runs on.
            var out = "<bos>"
            var pendingSystem: String?
            for turn in turns {
                switch turn.role {
                case "system":
                    pendingSystem = [pendingSystem, turn.content]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                case "assistant":
                    out += "<start_of_turn>model\n\(turn.content)<end_of_turn>\n"
                default:
                    let content = [pendingSystem, turn.content]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                    pendingSystem = nil
                    out += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                }
            }
            if let pendingSystem {
                // A system prompt with no user turn after it. Rare, but it
                // must not vanish.
                out += "<start_of_turn>user\n\(pendingSystem)<end_of_turn>\n"
            }
            return out + "<start_of_turn>model\n"

        case .mistral:
            // Same story as Gemma: no system role, so it rides with the user
            // turn it applies to.
            var out = "<s>"
            var pendingSystem: String?
            for turn in turns {
                switch turn.role {
                case "system":
                    pendingSystem = [pendingSystem, turn.content]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                case "assistant":
                    out += " \(turn.content)</s>"
                default:
                    let content = [pendingSystem, turn.content]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                    pendingSystem = nil
                    out += "[INST] \(content) [/INST]"
                }
            }
            if let pendingSystem {
                out += "[INST] \(pendingSystem) [/INST]"
            }
            return out

        case .phi3:
            var out = ""
            for turn in turns {
                out += "<|\(turn.role)|>\n\(turn.content)<|end|>\n"
            }
            return out + "<|assistant|>\n"

        case .plain:
            var out = ""
            for turn in turns {
                out += "\(turn.role.capitalized): \(turn.content)\n\n"
            }
            return out + "Assistant:"
        }
    }

    /// Strings that mark the end of a turn for this template.
    ///
    /// Belt and braces alongside the model's own end token: a model that has
    /// been asked for structured output sometimes carries on and starts writing
    /// the *user's* next turn, and cutting at the marker is what stops that
    /// reaching the parser.
    public var stopSequences: [String] {
        switch concreteFallback {
        case .chatML, .modelDefault: return ["<|im_end|>", "<|im_start|>"]
        case .llama3: return ["<|eot_id|>", "<|start_header_id|>"]
        case .gemma: return ["<end_of_turn>", "<start_of_turn>"]
        case .mistral: return ["</s>", "[INST]"]
        case .phi3: return ["<|end|>", "<|user|>"]
        case .plain: return ["\nUser:", "\nSystem:"]
        }
    }

    /// The best guess for a model family, when the catalog does not say.
    ///
    /// A guess, and only consulted after the file's own template and the
    /// catalog's declaration have both come up empty. ChatML is the default
    /// because it is what most instruct fine-tunes use.
    public static func inferred(fromArchitecture architecture: String) -> LocalChatTemplate {
        let name = architecture.lowercased()
        if name.hasPrefix("gemma") { return .gemma }
        if name.hasPrefix("phi") { return .phi3 }
        if name.contains("mistral") || name.contains("mixtral") { return .mistral }
        if name.hasPrefix("llama") { return .llama3 }
        return .chatML
    }
}
