import AssistantDomain
import XCTest
@testable import AssistantPersistence

final class CredentialStoreTests: XCTestCase {
    private let key = CredentialKey.remoteAIAPIKey(providerID: "remote.openai-compatible")

    func testStoresAndReadsBack() async throws {
        let store = EphemeralCredentialStore()

        let stored1 = try await store.credential(for: key)
        XCTAssertNil(stored1)

        try await store.setCredential("a-secret", for: key)
        let stored2 = try await store.credential(for: key)
        XCTAssertEqual(stored2, "a-secret")
    }

    func testAnEmptyValueClearsRatherThanStoringBlank() async throws {
        let store = EphemeralCredentialStore()
        try await store.setCredential("a-secret", for: key)

        try await store.setCredential("", for: key)
        let stored1 = try await store.credential(for: key)
        XCTAssertNil(stored1)

        try await store.setCredential("a-secret", for: key)
        try await store.setCredential(nil, for: key)
        let stored2 = try await store.credential(for: key)
        XCTAssertNil(stored2)
    }

    func testRemoving() async throws {
        let store = EphemeralCredentialStore()
        try await store.setCredential("a-secret", for: key)

        try await store.removeCredential(for: key)
        let stored = try await store.credential(for: key)
        XCTAssertNil(stored)

        // Removing something absent is not an error.
        try await store.removeCredential(for: key)
    }

    func testKeysAreScopedPerProvider() async throws {
        let store = EphemeralCredentialStore()
        let other = CredentialKey.remoteAIAPIKey(providerID: "remote.something-else")

        try await store.setCredential("first", for: key)
        try await store.setCredential("second", for: other)

        let stored1 = try await store.credential(for: key)
        XCTAssertEqual(stored1, "first")
        let stored2 = try await store.credential(for: other)
        XCTAssertEqual(stored2, "second")
        XCTAssertNotEqual(key, other)
    }

    func testTheKeyNameDoesNotContainTheSecret() {
        // The key is an identifier, not a value — it is safe to log.
        XCTAssertEqual(
            key.description,
            "ai.provider.remote.openai-compatible.apiKey"
        )
    }
}
