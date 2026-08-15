// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantPersistence
import Foundation
import Security

/// Keychain-backed secret storage.
///
/// The only place an API key is written. `kSecAttrAccessibleAfterFirstUnlock`
/// with `ThisDeviceOnly` means the key survives a relaunch, is available to
/// background work after the first unlock, and is never carried into an
/// encrypted backup or onto another device.
///
/// TODO-XCODE: unverified. This has not been run against a real Keychain. The
/// query shapes are standard, but behaviour on first write, on overwrite, and
/// in the Simulator's keychain needs checking on a Mac before it is trusted.
actor KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.example.personalassistant") {
        self.service = service
    }

    func credential(for key: CredentialKey) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.storageFailure(status: status)
        }
        guard
            let data = item as? Data,
            let text = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.unexpectedFormat
        }
        return text.isEmpty ? nil : text
    }

    func setCredential(_ credential: String?, for key: CredentialKey) async throws {
        guard let credential, !credential.isEmpty else {
            try await removeCredential(for: key)
            return
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let data = Data(credential.utf8)

        // Update in place when an item already exists; the Keychain rejects a
        // second add for the same service/account pair.
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.storageFailure(status: updateStatus)
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.storageFailure(status: addStatus)
        }
    }

    func removeCredential(for key: CredentialKey) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.storageFailure(status: status)
        }
    }
}
