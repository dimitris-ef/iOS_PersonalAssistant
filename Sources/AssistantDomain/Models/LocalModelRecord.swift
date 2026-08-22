import Foundation

/// A model file that is installed on this device.
///
/// ## Why this is in the domain and not next to the runtime
///
/// Because it is the app's record of a file it owns, and the app owns it
/// whether or not any inference runtime is linked into the build. Putting it
/// here is also what keeps `AssistantPersistence` from having to depend on a
/// provider module in order to store a row.
///
/// What it deliberately does not hold: anything about how the model is *run*.
/// No context pointer, no runtime handle, no loaded state. This survives a
/// relaunch; none of those do.
///
/// ## Why the path is relative
///
/// iOS relocates an app's container between installs and across restores, so an
/// absolute path recorded today can name nothing tomorrow — or, worse, name
/// something else. What is stored is the path within the app's models
/// directory, and the absolute URL is rebuilt from the current container every
/// time the file is opened.
public struct LocalModelRecord: Hashable, Codable, Sendable, Identifiable {
    /// The logical model identifier from the catalog, never a filename.
    public var id: AIModelIdentifier
    /// Path within the models directory, e.g. "qwen3-1.7b-q4-k-m.gguf".
    public var relativePath: String
    public var fileSizeBytes: Int64
    /// SHA-256 of the bytes that were installed.
    ///
    /// Recorded whether or not the catalog published one to compare against, so
    /// a later integrity check has a baseline for detecting on-disk corruption.
    public var checksumSHA256: String?
    /// True when the catalog published a checksum and the download matched it.
    /// False means the file passed structural checks only, which the model
    /// detail screen says out loud rather than implying a verification that did
    /// not happen.
    public var checksumWasDeclared: Bool
    public var installedAt: Date
    public var lastUsedAt: Date?
    /// The architecture read out of the file's own header — "qwen3", "llama" —
    /// rather than the architecture the catalog claimed.
    public var architecture: String?
    /// The quantization as the runtime names it, e.g. "Q4_K_M". A string
    /// because quantization families are added upstream faster than this app is
    /// rebuilt, and an unrecognised one must round-trip rather than fail to
    /// decode.
    public var quantization: String?
    /// The context length this model is opened with, after clamping against
    /// what the weights support and what the device can hold.
    public var contextLength: Int

    public init(
        id: AIModelIdentifier,
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
        self.id = id
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
