import AssistantDomain
import Foundation

/// Secure storage for secrets.
///
/// Separate from the repositories on purpose: an API key is not application
/// data. It never appears in `AssistantSettings`, is never encoded into the
/// JSON snapshot, and is never carried inside a configuration struct where it
/// could reach a log or a `description`.
///
/// Read-only access for providers goes through `CredentialProvider` in
/// `AIProviderRemote`, which is a narrower protocol. That keeps the provider
/// modules from depending on persistence at all — the composition root bridges
/// the two.
public protocol CredentialStore: Sendable {
    func credential(for key: CredentialKey) async throws -> String?
    func setCredential(_ credential: String?, for key: CredentialKey) async throws
    func removeCredential(for key: CredentialKey) async throws
}

/// Names a stored secret. A plain string wrapper so keys cannot be confused
/// with the values they retrieve.
public struct CredentialKey: Hashable, Sendable, ExpressibleByStringLiteral,
                             CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// The API key for a remote AI provider.
    public static func remoteAIAPIKey(providerID: AIProviderIdentifier) -> CredentialKey {
        CredentialKey("ai.provider.\(providerID.rawValue).apiKey")
    }
}

/// In-memory store, for tests, previews and the CLI harness.
///
/// Nothing survives the process, which is the point: a development build should
/// not quietly accumulate secrets on disk.
public actor EphemeralCredentialStore: CredentialStore {
    private var storage: [CredentialKey: String] = [:]

    public init(seed: [CredentialKey: String] = [:]) {
        self.storage = seed
    }

    public func credential(for key: CredentialKey) async throws -> String? {
        let value = storage[key]
        return value?.isEmpty == true ? nil : value
    }

    public func setCredential(_ credential: String?, for key: CredentialKey) async throws {
        if let credential, !credential.isEmpty {
            storage[key] = credential
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func removeCredential(for key: CredentialKey) async throws {
        storage.removeValue(forKey: key)
    }
}

public enum CredentialStoreError: Error, Hashable, Sendable {
    case storageFailure(status: Int32)
    case unexpectedFormat
}
