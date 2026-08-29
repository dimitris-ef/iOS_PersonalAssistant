import AssistantAI
import Foundation

/// Which slice of the model list to show.
///
/// Deliberately few. A filter row that scrolls is a filter row nobody reads,
/// and these five answer the questions people actually arrive with: what is
/// here, what will run, what have I already got, what have I not, and what
/// should I pick if I do not want to think about it.
public enum LocalModelFilter: String, CaseIterable, Sendable, Identifiable {
    case all
    case compatible
    case downloaded
    case notDownloaded
    case recommended

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .compatible: return "Compatible"
        case .downloaded: return "Downloaded"
        case .notDownloaded: return "Not Downloaded"
        case .recommended: return "Recommended"
        }
    }

    func matches(_ status: LocalModelStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .compatible:
            // "Would run here", not "is perfect here": a model with a warning
            // still runs, and hiding it would silently narrow the list on
            // exactly the older phones that most need to see their options.
            return status.compatibility.permitsDownload || status.lifecycle.isInstalled
        case .downloaded:
            return status.lifecycle.isInstalled
        case .notDownloaded:
            return !status.lifecycle.isInstalled
        case .recommended:
            return Self.isRecommended(status)
        }
    }

    /// Recommended means: it fits comfortably, its quantization is one this app
    /// vouches for, and it can be run.
    ///
    /// Not a performance claim. Nothing here has been benchmarked on a phone,
    /// so the label says "we would start here", not "this is fast" — section 26.
    static func isRecommended(_ status: LocalModelStatus) -> Bool {
        // An entry with no declared quantization is not recommended against —
        // it simply has not said enough about itself to be recommended for.
        guard status.descriptor.quantization?.isRecommended == true else { return false }
        switch status.compatibility {
        case .compatible:
            return true
        case .compatibleWithWarning, .likelyTooLarge, .unsupportedFormat,
             .unsupportedArchitecture, .unsupportedOS, .insufficientStorage, .unknown:
            return false
        }
    }
}

/// Searching and filtering the model list.
///
/// A free function over statuses rather than a method on the view model, so it
/// can be tested without SwiftUI — `iOS/` has no test target, and the rule that
/// decides which models a person can see is worth more than a rule that decides
/// how they are drawn.
public enum LocalModelSearch {

    /// Applies a filter and a query together.
    ///
    /// Section 29: they compose. "Downloaded" plus "qwen" means downloaded Qwen
    /// models, not one or the other — a filter that silently ignored the query
    /// would be worse than having neither, because the list would look
    /// authoritative and be wrong.
    public static func apply(
        filter: LocalModelFilter,
        query: String,
        to statuses: [LocalModelStatus]
    ) -> [LocalModelStatus] {
        statuses
            .filter { filter.matches($0) }
            .filter { matches(query: query, $0) }
    }

    /// Whether a model matches a free-text query.
    ///
    /// Matches the fields somebody would actually type: the name, the family,
    /// the GGUF architecture, the quantization, and the parameter count in the
    /// form it is written ("1.7B"). Case- and diacritic-insensitive, because a
    /// search box that cares about capitals is a search box that appears broken.
    public static func matches(query: String, _ status: LocalModelStatus) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let descriptor = status.descriptor
        let haystack = [
            descriptor.displayName,
            descriptor.architecture,
            descriptor.quantization?.rawValue ?? "",
            descriptor.parameterLabel ?? "",
            descriptor.summary ?? "",
        ].joined(separator: " ")

        return haystack.range(
            of: trimmed,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}
