import AssistantDomain
import Foundation

/// Why a model was given the action capability it has.
///
/// ## Why the reason is tracked and not just the answer
///
/// Section 4. "Chat only" on a screen is unarguable — there is nothing for the
/// person looking at it to check, and nothing for the next reader of a bug
/// report to disagree with. "Chat only, because no curated entry matched and
/// the architecture is not a known tool-calling family" is a claim with a
/// mechanism behind it, and a wrong one is visibly wrong.
///
/// The UI never invents this: it renders what the resolver decided.
public enum LocalModelCapabilitySource: String, Hashable, Sendable, Codable, CaseIterable {
    /// The curated catalogue names this exact model. The strongest evidence
    /// there is: somebody chose it deliberately for this app's tool protocol.
    case curatedCatalog
    /// The chat template is one whose tool-call format is recognised.
    case recognizedChatTemplate
    /// The architecture belongs to a family known to emit structured calls.
    case knownModelFamily
    /// Metadata read out of an imported file.
    case importedMetadata
    /// The user said so.
    case userOverride
    /// Carried forward from a build that recorded capability differently.
    case legacyMigration
    /// Nothing matched. The capability is the conservative default, not a
    /// finding.
    case unknown

    public var label: String {
        switch self {
        case .curatedCatalog: return "Curated catalog"
        case .recognizedChatTemplate: return "Recognized tool template"
        case .knownModelFamily: return "Known model family"
        case .importedMetadata: return "Imported model metadata"
        case .userOverride: return "Set by you"
        case .legacyMigration: return "Migrated from an earlier version"
        case .unknown: return "Not determined"
        }
    }
}

/// What a model may be asked to do, and on what grounds.
public struct LocalModelCapabilityResolution: Hashable, Sendable {
    public var capability: LocalModelToolSupport
    public var source: LocalModelCapabilitySource

    public init(capability: LocalModelToolSupport, source: LocalModelCapabilitySource) {
        self.capability = capability
        self.source = source
    }

    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.toolCapability, capability.rawValue)
            .setting(.capabilitySource, source.rawValue)
    }
}

/// Decides whether a model on this device may be asked to carry out actions.
///
/// ## The gap this closes
///
/// Capability used to exist in exactly one place — a field on the curated
/// catalogue entry — and was read by joining an installed model back to that
/// entry at the moment somebody looked at it. Nothing was stored with the
/// model, so anything the join could not reach had no capability at all: a
/// model whose catalogue id changed between builds, or an imported file that
/// was never in the catalogue.
///
/// ## Why a resolver rather than a new persisted column
///
/// Sections 8 to 13 all ask for capability to *survive* — download, import,
/// load, unload, restart, selection. A stored column survives those by being
/// written once and read back. A deterministic function of already-persisted
/// evidence survives them by never varying in the first place, which is the
/// stronger property: there is no window in which a record exists without the
/// field, no default to be written by a build that did not know about it, and
/// no migration to get wrong on somebody's real data.
///
/// It also makes section 16 unnecessary rather than merely satisfied. There is
/// no stale capability to reconcile, because none was ever stored to go stale —
/// a model wrongly classified by an old build is classified correctly the
/// moment this build reads it, with no redownload and no migration pass.
///
/// The inputs — the catalogue, the record's `id` and its `architecture`, read
/// from the file's own GGUF header at install — all persist already.
///
/// ## What it must never do
///
/// Section 2, a hard requirement: **parameter count is not evidence.** A 3B
/// model is not action-capable because it is large, and a 0.5B one is not
/// incapable because it is small — tool use comes from what the model was
/// trained and templated to emit. `LocalModelCapabilityTests` asserts that two
/// models identical but for their size resolve identically.
public enum LocalModelCapabilityResolver {

    /// Architectures whose instruct tunes emit structured calls dependably
    /// enough to be worth offering tools to.
    ///
    /// Conservative on purpose (section 17): this is the fallback for a model
    /// with no curated entry, and everything it matches gets `.experimental` —
    /// offered, with the honest label — never `.supported`. Claiming full
    /// support on family evidence alone would be exactly the indiscriminate
    /// marking section 6 forbids.
    public static let toolCapableFamilies: Set<String> = ["qwen2", "qwen3", "llama"]

    /// Chat templates whose tool-call format this app recognises.
    public static let toolCapableTemplates: Set<LocalChatTemplate> = [.chatML]

    /// The capability for a model that is installed on this device.
    ///
    /// `descriptor` is the curated entry when one matched. `record` is what was
    /// written at install time, including the architecture read from the file's
    /// own header rather than from anything the catalogue claimed.
    public static func resolve(
        descriptor: LocalModelDescriptor?,
        record: LocalModelRecord?
    ) -> LocalModelCapabilityResolution {
        // 1. Somebody chose this model for this app. Nothing beats that.
        if let descriptor {
            return LocalModelCapabilityResolution(
                capability: descriptor.toolSupport, source: .curatedCatalog
            )
        }

        // 2. A template whose tool format is recognised.
        if let template = record?.chatTemplateKind,
            toolCapableTemplates.contains(template) {
            return LocalModelCapabilityResolution(
                capability: .experimental, source: .recognizedChatTemplate
            )
        }

        // 3. The family, from the file's own header.
        if let architecture = record?.architecture?.lowercased(),
            toolCapableFamilies.contains(where: { architecture.hasPrefix($0) }) {
            return LocalModelCapabilityResolution(
                capability: .experimental, source: .knownModelFamily
            )
        }

        // 4. Nothing to go on. Section 7: offered, labelled experimental, and
        // recorded as a default rather than a finding — the tool pipeline's own
        // safeguards still stand behind it, and refusing outright would block a
        // capable model on no evidence at all.
        return LocalModelCapabilityResolution(capability: .experimental, source: .unknown)
    }

    /// Convenience for a catalogue model that may or may not be installed.
    public static func resolve(status: LocalModelStatus) -> LocalModelCapabilityResolution {
        resolve(descriptor: status.descriptor, record: status.installed)
    }
}

extension LocalModelRecord {
    /// The chat template recorded for this install, if the format is one this
    /// build knows.
    ///
    /// `LocalModelRecord` stores the quantization and architecture the GGUF
    /// header actually declared; the template is derived from the architecture
    /// when the header did not name one, which is why this is computed rather
    /// than stored.
    var chatTemplateKind: LocalChatTemplate? {
        guard let architecture = architecture?.lowercased() else { return nil }
        if architecture.hasPrefix("qwen") { return .chatML }
        if architecture.hasPrefix("smollm") { return .chatML }
        return nil
    }
}
