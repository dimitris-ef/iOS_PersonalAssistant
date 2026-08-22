import AssistantAI
import AssistantDomain
import Foundation

/// The models this app offers to download.
///
/// ## Curated, not a marketplace
///
/// Sections 14 and 127. The list is small, checked in, and maintained by
/// whoever ships the app. What it is not is a browser for every GGUF on the
/// internet: a text field that fetches an arbitrary URL is a text field that
/// downloads whatever someone was told to paste into it, and "it validated as a
/// GGUF" is not the same as "it is safe to run against your calendar".
///
/// ## No weights in the repository
///
/// Section 16. The catalog holds *descriptions* — a name, a size, a licence and
/// an HTTPS address. The weights are fetched from wherever their publisher put
/// them, on the user's device, when the user asks.
public struct LocalModelCatalog: Sendable {
    public private(set) var models: [LocalModelDescriptor]

    public init(models: [LocalModelDescriptor] = []) {
        self.models = models
    }

    public func descriptor(for id: AIModelIdentifier) -> LocalModelDescriptor? {
        models.first { $0.id == id }
    }

    /// Adds or replaces an entry. Used for imported files and by tests.
    public mutating func upsert(_ descriptor: LocalModelDescriptor) {
        if let index = models.firstIndex(where: { $0.id == descriptor.id }) {
            models[index] = descriptor
        } else {
            models.append(descriptor)
        }
    }

    /// Decodes a catalog from JSON.
    public static func decode(_ data: Data) throws -> LocalModelCatalog {
        let file = try JSONCoding.decoder.decode(CatalogFile.self, from: data)
        return LocalModelCatalog(models: file.models)
    }

    /// The catalog shipped with this build.
    ///
    /// Loaded from the bundled JSON. If that ever fails — a build that lost its
    /// resources, a decoding change — the result is an *empty* catalog rather
    /// than a crash or a hard-coded fallback list: Local AI then reports that
    /// no models are available, which is true and recoverable, whereas a
    /// duplicate list in Swift would be a second thing to keep correct.
    public static func bundled() -> LocalModelCatalog {
        guard
            let url = Bundle.module.url(forResource: "local-models", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? decode(data)
        else {
            return LocalModelCatalog()
        }
        return catalog
    }

    /// The JSON file's shape. Versioned so the format can change without every
    /// old build failing to read a newer file.
    struct CatalogFile: Codable {
        var version: Int
        var models: [LocalModelDescriptor]
    }
}
