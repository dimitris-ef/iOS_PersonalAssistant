import AssistantAI
import AssistantDomain
import Foundation

/// Keeps a prompt inside the context the model was actually opened with.
///
/// ## The failure this prevents
///
/// Section 52. A conversation plus its retrieved memories plus the tool schemas
/// grows without anybody watching, and a phone-sized context is small — 2048
/// tokens on a 4 GB device. llama.cpp does not politely truncate an oversized
/// prompt: it is asked to decode more tokens than the context holds, and what
/// happens next is somewhere between a wrong answer, a `GGML_ASSERT` and a
/// process that stops existing.
///
/// The limit that matters is the one the runtime *got*, not the one the catalog
/// advertises. `LocalModelManager` shrinks the context to fit available memory,
/// so a model whose record says 4096 may well be running at 1024 — which is why
/// this takes a ``LocalInferenceConfiguration`` and the provider reads it from
/// `activeConfiguration()` rather than from the descriptor.
///
/// ## Why the estimate is a division
///
/// There is no tokenizer at this layer, and there should not be one: getting to
/// the real tokenizer means having the model loaded and reaching through the
/// runtime protocol for a count, which couples the provider to llama.cpp for a
/// number it only needs approximately. Four characters per token is the
/// standard rough figure for English, and this rounds *up* everywhere and adds
/// per-turn overhead for the template markers, so the estimate errs toward
/// trimming one turn too many rather than one too few. Being slightly too
/// cautious costs a line of old conversation; being slightly too generous costs
/// the app.
public enum LocalPromptBudget {

    /// Bytes of text per token, roughly, for the languages these models see.
    static let charactersPerToken = 4
    /// Tokens a chat template spends per turn on role markers and separators.
    /// Generous on purpose — this is the term a naive estimate forgets, and it
    /// is the one that scales with the number of turns.
    static let perTurnOverheadTokens = 8

    /// A rough token count for one string.
    public static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.count + charactersPerToken - 1) / charactersPerToken
    }

    /// A rough token count for a whole prompt, template overhead included.
    public static func estimatedTokens(in prompt: LocalPrompt) -> Int {
        prompt.turns.reduce(0) { total, turn in
            total + estimatedTokens(in: turn.content) + perTurnOverheadTokens
        }
    }

    /// Trims a prompt until it fits, and says whether it had to.
    ///
    /// What is kept, in order of stubbornness:
    ///
    /// 1. **Every system turn.** It carries the app's instructions and the tool
    ///    protocol; dropping it produces a model that has forgotten what it is
    ///    and cannot form an action, which is far worse than a short memory.
    /// 2. **The most recent user turn.** Dropping the message somebody just
    ///    typed to make room for the conversation about it is absurd, so it
    ///    survives even when it alone exceeds the budget — truncated in place
    ///    rather than removed.
    /// 3. **The newest history first**, oldest dropped, because recency is what
    ///    a follow-up question depends on.
    public static func fit(
        _ prompt: LocalPrompt,
        configuration: LocalInferenceConfiguration
    ) -> LocalPromptFit {
        let limit = max(64, configuration.maximumPromptTokens)
        let original = estimatedTokens(in: prompt)
        guard original > limit else {
            return LocalPromptFit(prompt: prompt, wasTrimmed: false, droppedTurns: 0)
        }

        let systemTurns = prompt.turns.filter { $0.role == "system" }
        var history = prompt.turns.filter { $0.role != "system" }

        // The last turn is the one being answered. Held aside so the newest
        // history can be walked backwards without it being a special case in
        // the loop.
        let latest = history.popLast()

        var systemCost = systemTurns.reduce(0) {
            $0 + estimatedTokens(in: $1.content) + perTurnOverheadTokens
        }
        var trimmedSystem = systemTurns

        var kept: [LocalChatTurn] = []
        var latestTurn = latest
        var latestCost = 0
        if var turn = latestTurn {
            // Room for the newest message is reserved before any history is
            // considered — and if it does not fit even on its own, it is cut
            // down rather than dropped. A truncated question is answerable; a
            // missing one is not.
            let available = max(64, limit - systemCost)
            if estimatedTokens(in: turn.content) + perTurnOverheadTokens > available {
                turn.content = truncate(
                    turn.content,
                    toTokens: max(32, available - perTurnOverheadTokens)
                )
            }
            latestCost = estimatedTokens(in: turn.content) + perTurnOverheadTokens
            latestTurn = turn
        }

        // If the system prompt alone is what will not fit, it is truncated too
        // — but last, and only because the alternative is a prompt that cannot
        // be sent at all.
        if systemCost + latestCost > limit, !trimmedSystem.isEmpty {
            let allowance = max(64, limit - latestCost)
            trimmedSystem = truncateSystem(trimmedSystem, toTokens: allowance)
            systemCost = trimmedSystem.reduce(0) {
                $0 + estimatedTokens(in: $1.content) + perTurnOverheadTokens
            }
        }

        var used = systemCost + latestCost
        for turn in history.reversed() {
            let cost = estimatedTokens(in: turn.content) + perTurnOverheadTokens
            guard used + cost <= limit else { break }
            used += cost
            kept.insert(turn, at: 0)
        }

        var turns = trimmedSystem
        turns.append(contentsOf: kept)
        if let latestTurn { turns.append(latestTurn) }

        return LocalPromptFit(
            prompt: LocalPrompt(turns: turns, fallback: prompt.fallback),
            wasTrimmed: true,
            droppedTurns: history.count - kept.count
        )
    }

    /// The reply length that leaves the context intact.
    ///
    /// The model may not be asked for more tokens than the context has room for
    /// after the prompt, whatever the request wanted. This is the second half of
    /// section 53: bounding the prompt alone still allows a 2048-token context
    /// to be given a 1900-token prompt and asked for 640 tokens back.
    public static func generationLimit(
        promptTokens: Int,
        requested: Int,
        configuration: LocalInferenceConfiguration
    ) -> Int {
        let room = configuration.contextLength - promptTokens
        // A floor of 32 rather than zero: a reply of no tokens is not an
        // outcome anything upstream can render, and the prompt fitting above
        // has already guaranteed the reserve.
        return max(32, min(requested, max(32, room)))
    }

    // MARK: Cutting text

    /// Keeps the **end** of a string.
    ///
    /// The tail, not the head: the last sentences of a long message are the
    /// ones the question is in, and an ellipsis at the front tells the model
    /// something was removed rather than letting it answer a fragment as though
    /// it were the whole thing.
    static func truncate(_ text: String, toTokens tokens: Int) -> String {
        let characters = max(0, tokens) * charactersPerToken
        guard text.count > characters else { return text }
        let tail = String(text.suffix(max(0, characters - marker.count)))
        return marker + tail
    }

    static let marker = "…"

    private static func truncateSystem(
        _ turns: [LocalChatTurn],
        toTokens tokens: Int
    ) -> [LocalChatTurn] {
        guard var last = turns.last else { return turns }
        let others = turns.dropLast()
        let othersCost = others.reduce(0) {
            $0 + estimatedTokens(in: $1.content) + perTurnOverheadTokens
        }
        let allowance = max(32, tokens - othersCost - perTurnOverheadTokens)
        last.content = truncate(last.content, toTokens: allowance)
        return Array(others) + [last]
    }
}

/// A prompt that fits, and whether anything was lost getting it there.
///
/// `wasTrimmed` is not decoration: it is what lets the assistant say the
/// conversation is running long instead of quietly forgetting the first half of
/// it, which from the user's side is indistinguishable from the model being bad
/// at its job.
public struct LocalPromptFit: Hashable, Sendable {
    public let prompt: LocalPrompt
    public let wasTrimmed: Bool
    public let droppedTurns: Int

    public init(prompt: LocalPrompt, wasTrimmed: Bool, droppedTurns: Int) {
        self.prompt = prompt
        self.wasTrimmed = wasTrimmed
        self.droppedTurns = droppedTurns
    }
}
