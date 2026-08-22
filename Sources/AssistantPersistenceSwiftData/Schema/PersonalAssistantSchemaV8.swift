#if canImport(SwiftData)

import Foundation
import SwiftData

// Schema version 8: downloadable local models.
//
// Two additions:
//
//  1. `SDLocalModel`, a new entity. One row per model file the user has
//     downloaded: its logical identifier, where it sits inside the models
//     directory, how big it is, what its checksum was, what the file's own
//     header said it is, and the context length it gets opened with.
//
//  2. `SDAssistantSettings.selectedLocalModelID`, one nullable column, naming
//     which of those models Local AI should use.
//
// ## What is emphatically not here
//
// The weights. Section 26: a model file is one to five gigabytes of tensors,
// and putting one in a SwiftData blob means it is loaded, copied and — worst of
// all — carried through every future migration by machinery designed for rows.
// The file lives on the filesystem under Application Support/Models, and this
// row is a description of it.
//
// Nor is anything about the *loaded* model persisted. A loaded model is a
// native allocation and a Metal command queue; there is no version of that
// which survives the process ending, and a column claiming otherwise would be a
// column storing a stale pointer. Section 64 asks for the *selection* to be
// remembered, which is what the settings column does.
//
// ## Why the path is relative and the identifier is not a path
//
// Section 27. An app container is relocated by iOS on restore and on some
// updates, so an absolute path recorded in one launch may name nothing in the
// next. `relativePath` is resolved against the current container each time, and
// `id` is the catalog's logical identifier — stable across every one of those
// moves, and the thing settings actually refers to.
//
// ## Why this stays inferrable
//
// A new entity, plus one optional column on an existing one. That is the case
// SwiftData resolves from the store's own metadata, so the stage is
// `.lightweight` — see the note in `PersonalAssistantSchemaV2` for what would
// make it not be.
//
// ## What an existing store becomes
//
// Exactly what it was, with no models installed and none selected — which is
// the truth for anyone upgrading, since there was no way to download one
// before this version.

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public enum PersonalAssistantSchemaV8: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SDConversation.self,
            SDMessage.self,
            SDActionPlan.self,
            SDAction.self,
            SDToolResult.self,
            SDMemory.self,
            SDMemoryRelation.self,
            SDMemoryEmbedding.self,
            SDTask.self,
            SDRoutine.self,
            SDReminderPlan.self,
            SDReminderStage.self,
            SDAssistantSettings.self,
            SDUserProfile.self,
            SDLocalModel.self,
        ]
    }
}

/// One downloaded model file.
///
/// Keyed by the catalog's logical identifier, so re-downloading a model updates
/// the row it already had rather than accumulating a second one describing the
/// same file.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@Model
public final class SDLocalModel {
    /// The catalog identifier, e.g. "qwen3-1.7b-q4-k-m". Never a path.
    @Attribute(.unique) public var modelID: String
    /// Path inside the models directory. Resolved against the current
    /// container on every use.
    public var relativePath: String
    public var fileSizeBytes: Int64
    /// SHA-256 of the bytes that were installed. Recorded whether or not the
    /// catalog had one to compare against, so a later integrity check has a
    /// baseline.
    public var checksumSHA256: String?
    /// True when the catalog published a checksum and the download matched it.
    public var checksumWasDeclared: Bool
    public var installedAt: Date
    public var lastUsedAt: Date?
    /// Read out of the file's own GGUF header rather than taken from the
    /// catalog — section 116.
    public var architecture: String?
    /// "Q4_K_M" and friends. A string, because quantization families are added
    /// upstream faster than this app ships, and an unfamiliar one must survive
    /// a round trip rather than fail to decode.
    public var quantization: String?
    /// The context this model is opened with, already clamped against the
    /// weights and the device.
    public var contextLength: Int

    public init(
        modelID: String,
        relativePath: String,
        fileSizeBytes: Int64,
        checksumSHA256: String? = nil,
        checksumWasDeclared: Bool = false,
        installedAt: Date,
        lastUsedAt: Date? = nil,
        architecture: String? = nil,
        quantization: String? = nil,
        contextLength: Int
    ) {
        self.modelID = modelID
        self.relativePath = relativePath
        self.fileSizeBytes = fileSizeBytes
        self.checksumSHA256 = checksumSHA256
        self.checksumWasDeclared = checksumWasDeclared
        self.installedAt = installedAt
        self.lastUsedAt = lastUsedAt
        self.architecture = architecture
        self.quantization = quantization
        self.contextLength = contextLength
    }
}

#endif
