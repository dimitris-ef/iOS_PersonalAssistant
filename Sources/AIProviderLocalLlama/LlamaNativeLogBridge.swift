import AIProviderLocal
import Foundation

#if canImport(llama)
import llama
#endif

/// Routes llama.cpp's own log output into the diagnostic trail.
///
/// ## Why this matters more than it looks
///
/// Section 34. If llama.cpp hits an assertion inside `llama_decode`, it prints
/// and then calls `abort()`. Swift never gets control back, no error is thrown,
/// and the only trace of *why* is the line it printed on the way out. On a
/// device there is no console to print to — so unless that line is captured and
/// flushed synchronously, the single most informative sentence in the whole
/// failure is lost.
///
/// So warnings and errors are written straight through the critical path, with
/// the same `write(2)` guarantee as an ENTER breadcrumb. Informational noise —
/// and llama.cpp is very talkative at load time — obeys the verbose setting.
///
/// ## The callback runs on whatever thread ggml is on
///
/// Possibly several at once, during a threaded decode. The logger is
/// lock-serialized and synchronous, which is exactly what a C callback with no
/// async context can use; anything actor-based would be uncallable from here.
public enum LlamaNativeLogBridge {

    /// The sink installed callbacks write to. A global because `llama_log_set`
    /// takes a C function pointer plus one `void *`, and the C function pointer
    /// cannot capture — there is nowhere else for it to live.
    ///
    /// Guarded by its own lock rather than assumed single-threaded: install
    /// happens on the main actor at launch, and the callback fires on ggml's
    /// worker threads.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (any LocalInferenceDiagnosticSink)?

    /// Takes llama.cpp's log output away from stderr, whether or not anything
    /// is listening yet.
    ///
    /// This is the privacy half and it must happen before the first model load.
    /// llama.cpp's default writes to stderr, and at its default level it prints
    /// text derived from the prompt — the user's messages and memories going to
    /// the system log. With the callback installed and no sink set, every line
    /// is simply dropped.
    ///
    /// Idempotent, and safe in either order relative to ``install(_:)``:
    /// activation never touches the sink, and installing a sink never has to
    /// re-point the callback.
    public static func activate() {
        #if canImport(llama)
        llama_log_set(
            { level, text, _ in
                LlamaNativeLogBridge.receive(level: level, text: text)
            },
            nil
        )
        #endif
    }

    /// Points the captured lines at the diagnostic trail.
    public static func install(_ diagnostics: any LocalInferenceDiagnosticSink) {
        lock.lock()
        sink = diagnostics
        lock.unlock()
        activate()
    }

    /// Stops recording native lines. The callback stays installed, because
    /// handing llama.cpp back its stderr default would put prompt-derived text
    /// in the system log.
    public static func uninstall() {
        lock.lock()
        sink = nil
        lock.unlock()
        activate()
    }

    #if canImport(llama)
    /// Turns one native line into a diagnostic event.
    ///
    /// `ggml_log_level` is a C enum; the numeric values are compared rather
    /// than switched over named cases so that a level added upstream degrades
    /// to "treat it as informational" instead of failing to compile.
    static func receive(level: ggml_log_level, text: UnsafePointer<CChar>?) {
        guard let text else { return }
        let raw = String(cString: text)
        deliver(levelValue: Int(level.rawValue), text: raw)
    }
    #endif

    /// The platform-independent half, so the behaviour is testable without
    /// llama.cpp linked.
    static func deliver(levelValue: Int, text raw: String) {
        lock.lock()
        let target = sink
        lock.unlock()
        guard let target else { return }

        let severity = LlamaNativeLogSeverity(ggmlLevel: levelValue)
        guard let message = LlamaNativeLogSanitizer.sanitize(raw) else { return }

        // Warnings and errors are part of the crash trail and are written
        // whatever the verbose setting is (section 31). Everything else is
        // load-time chatter.
        let level: LocalInferenceDiagnosticLevel
        switch severity {
        case .error: level = .error
        case .warning: level = .warning
        case .info, .debug: level = .debug
        }
        target.record(
            .nativeLog,
            type: severity == .error ? .error : (severity == .warning ? .warning : .info),
            level: level,
            category: .runtime,
            stage: nil,
            metadata: LocalInferenceMetadata()
                .setting(.nativeLogLevel, severity.rawValue)
                .setting(.errorReason, message)
        )
    }
}

/// How serious a native line is.
public enum LlamaNativeLogSeverity: String, Hashable, Sendable {
    case debug
    case info
    case warning
    case error

    /// `ggml_log_level` numbering, as the pinned header defines it:
    /// NONE=0, DEBUG=1, INFO=2, WARN=3, ERROR=4, CONT=5.
    ///
    /// `CONT` is a continuation of the previous line and carries no level of
    /// its own; it is treated as informational rather than guessed at.
    public init(ggmlLevel: Int) {
        switch ggmlLevel {
        case 4: self = .error
        case 3: self = .warning
        case 1: self = .debug
        default: self = .info
        }
    }
}

/// Decides what a native line may say in a log the user can share.
///
/// ## The risk being managed
///
/// Section 32. llama.cpp is not written with this app's privacy rules in mind,
/// and at high verbosity some builds print prompt fragments, detokenized pieces
/// or template output. None of that may reach a diagnostic file.
///
/// The approach is an allowlist of *topics*, not a blocklist of words. A line is
/// kept when it names something structural — a backend, an allocation, a tensor,
/// a KV cache, an assertion, a batch — and dropped otherwise. That is
/// deliberately conservative: it will discard some harmless lines, and the cost
/// of discarding a harmless line is far lower than the cost of keeping one that
/// carried a sentence somebody typed.
public enum LlamaNativeLogSanitizer {

    /// Topics worth keeping (section 32's own list, plus the assertion wording
    /// that precedes an abort).
    static let allowedTopics = [
        "backend", "metal", "gpu", "cpu", "device", "buffer", "alloc", "memory",
        "tensor", "assert", "error", "fail", "warn", "kv", "cache", "batch",
        "ubatch", "context", "ctx", "n_tokens", "seq", "slot", "graph", "compute",
        "model", "load", "gguf", "arch", "quant", "vocab", "thread", "abort",
        "invalid", "unsupported", "not enough", "out of", "cannot", "unable",
    ]

    /// Words that disqualify a line however structural it looks.
    ///
    /// Matched at a word boundary rather than anywhere in the line — see
    /// ``containsForbidden(_:)``.
    static let forbiddenTopics = [
        "prompt:", "prompt =", "text:", "token = '", "piece", "detokeniz",
        "chat template output", "formatted:", "user:", "assistant:",
    ]

    /// Whether a line names one of the forbidden topics *as a word*.
    ///
    /// ## Why a plain `contains` was wrong
    ///
    /// `"text:"` is a substring of `"context:"`, so a plain containment check
    /// discarded every `llama_context:` line — which is a large share of the
    /// structural output this whole bridge exists to keep, and it discarded them
    /// silently. The failure mode was the worst available: a log that looks
    /// complete and is missing exactly the lines about the thing being
    /// investigated.
    ///
    /// Only letters and digits count as word characters, so `_` is a boundary.
    /// That is deliberate rather than incidental: llama.cpp names things
    /// `n_token`, `n_ctx`, `n_batch`, and `"n_token = '"` must still be caught.
    static func containsForbidden(_ lowered: String) -> Bool {
        for topic in forbiddenTopics {
            var searchStart = lowered.startIndex
            while let found = lowered.range(of: topic, range: searchStart..<lowered.endIndex) {
                if found.lowerBound == lowered.startIndex { return true }
                let preceding = lowered[lowered.index(before: found.lowerBound)]
                if !preceding.isLetter && !preceding.isNumber { return true }
                searchStart = lowered.index(after: found.lowerBound)
            }
        }
        return false
    }

    /// A native line is at most this long in the log. llama.cpp prints long
    /// tables at load time and one of them would dominate a session file.
    public static let maximumLength = 180

    /// Returns the line to log, or nil to drop it.
    public static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if containsForbidden(lowered) { return nil }
        // The allowlist stays a plain containment check. It is the permissive
        // half, so a false positive here keeps a harmless line rather than
        // losing a needed one — and llama.cpp writes its topics as fragments
        // (`llama_kv_cache_init`, `ggml_metal_init`) that a boundary rule would
        // refuse.
        guard allowedTopics.contains(where: { lowered.contains($0) }) else { return nil }

        // Through the same redactor as every other free-text value, so the
        // length cap and control-character flattening are not reimplemented.
        let capped = trimmed.count > maximumLength
            ? String(trimmed.prefix(maximumLength - 1)) + "…"
            : trimmed
        return LocalInferenceRedaction.sanitizeText(capped)
    }
}
