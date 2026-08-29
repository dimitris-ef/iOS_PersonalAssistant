import AssistantAI
import AssistantDomain
import Foundation

/// One thing the assistant picker can be set to.
///
/// A provider, and for Local AI also which model — because "Local AI" alone is
/// not an answer to "what will reply to my next message" when three models are
/// downloaded (section 62).
public struct AssistantModelChoice: Identifiable, Hashable, Sendable {
    public let providerID: AIProviderIdentifier
    /// Nil for providers that expose one model, like Apple's.
    public let modelID: AIModelIdentifier?
    public let title: String
    /// The line underneath: a size and quantization, or a provider note.
    public let subtitle: String?

    public var id: String { "\(providerID.rawValue)|\(modelID?.rawValue ?? "")" }

    public init(
        providerID: AIProviderIdentifier,
        modelID: AIModelIdentifier?,
        title: String,
        subtitle: String?
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.title = title
        self.subtitle = subtitle
    }
}

/// Which local models may be offered as an assistant.
///
/// ## The rule this exists to hold
///
/// Section 22, and it is narrower than it first looks. A model appears in the
/// picker when it is **downloaded and compatible** — and *not* when it is
/// merely in the catalog, still downloading, incompatible, or in a failed
/// state. Loaded is deliberately not part of it: a downloaded model that is not
/// in memory is a perfectly good thing to select, and it will be loaded when
/// the first message needs it.
///
/// Getting this wrong is quiet. Offering a model that is still downloading
/// produces a picker entry that fails the moment it is used; requiring it to be
/// loaded produces a picker that is empty on every launch, because nothing is
/// loaded at launch by design.
public enum AssistantLocalChoices {

    /// The local models worth offering, in list order.
    public static func choices(from statuses: [LocalModelStatus]) -> [AssistantModelChoice] {
        statuses
            .filter(isSelectable)
            .map { status in
                AssistantModelChoice(
                    providerID: localProviderID,
                    modelID: status.id,
                    title: status.descriptor.displayName,
                    subtitle: subtitle(for: status)
                )
            }
    }

    /// Whether one model may be chosen as the assistant.
    public static func isSelectable(_ status: LocalModelStatus) -> Bool {
        // Installed covers downloaded, loading, loaded and unloading — every
        // state in which the file is on the device. A model mid-download is
        // not installed, which is what excludes it.
        guard status.lifecycle.isInstalled else { return false }
        // A file that is here but cannot run is not a choice. `permitsLoad`
        // rather than `permitsDownload`: storage no longer matters once the
        // file exists, but memory and architecture still do.
        guard status.compatibility.permitsLoad else { return false }
        // A model whose last load failed stays offered — the failure may have
        // been transient memory pressure, and Retry is the point. A model whose
        // *file* is broken does not.
        if case .failed = status.lifecycle { return false }
        if case .incompatible = status.lifecycle { return false }
        return true
    }

    /// "1.2 GB · Q4_K_M", with whatever half is actually known.
    static func subtitle(for status: LocalModelStatus) -> String? {
        var parts: [String] = []
        if let bytes = status.descriptor.fileSizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let quantization = status.descriptor.quantization {
            parts.append(quantization.rawValue)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The provider identifier the local models belong to.
    ///
    /// Read from `LocalModelProvider` rather than restated. A second literal
    /// here would be a second thing to keep in step, and a mismatch would
    /// produce a picker whose entries select a provider that does not exist —
    /// silently, because an unknown identifier is just an identifier.
    public static var localProviderID: AIProviderIdentifier { LocalModelProvider.providerID }
}
