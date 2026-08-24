import AssistantAI
import AssistantDomain
import Foundation
import NativeModelKit

/// Where language-model files live on disk.
///
/// The filesystem work itself is `NativeFileStore` in `NativeModelKit` — Part 13
/// stores Whisper weights the same way, and one implementation of "move a
/// verified download into place, atomically, excluded from backup" is enough.
/// What stays here is what makes this store Part 10's: the directory it uses,
/// and the fact that it can be addressed with a `LocalModelRecord`.
///
/// ## Why Application Support and not somewhere else
///
/// - **Not Documents.** On a phone with file sharing enabled, Documents is
///   what the Files app shows the user. A 2 GB blob they did not create,
///   cannot read and might delete does not belong there.
/// - **Not Caches.** iOS empties Caches when space runs low, without warning
///   and without telling the app. A model that vanishes on a full phone is a
///   model the user has to download again, having been told it was installed.
/// - **Not SwiftData.** Multi-gigabyte blobs in a database are loaded, copied
///   and migrated by machinery designed for rows.
public typealias LocalModelStore = NativeFileStore

extension NativeFileStore {

    /// The directory language-model weights live in, under Application Support.
    ///
    /// Speech models live in `Models/Speech` instead. The two never share a
    /// directory listing, which is what makes "delete the speech model" an
    /// operation that provably cannot reach the assistant's own weights.
    public static let languageModelSubdirectory = "Models"

    /// The production location: `Application Support/Models`.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> LocalModelStore {
        try applicationSupport(
            subdirectory: languageModelSubdirectory,
            fileManager: fileManager
        )
    }

    /// A throwaway directory. For tests and previews.
    public static func temporary(name: String = UUID().uuidString) -> LocalModelStore {
        temporary(prefix: "local-models", name: name)
    }

    /// The absolute URL of an installed model, resolved against the current
    /// container.
    ///
    /// Records store a relative path — the absolute path of an app container
    /// changes between installs and across device restores, so what is kept is
    /// `"qwen3-1.7b.gguf"` and the full URL is rebuilt each time it is needed.
    public func url(for model: LocalModelRecord) -> URL {
        url(forRelativePath: model.relativePath)
    }

    public func fileExists(_ model: LocalModelRecord) -> Bool {
        FileManager.default.fileExists(atPath: url(for: model).path)
    }
}
