import AssistantDomain
import XCTest
@testable import AssistantPersistence

final class CredentialStoreTests: XCTestCase {
    private let key = CredentialKey.remoteAIAPIKey(providerID: "remote.openai-compatible")

    func testStoresAndReadsBack() async throws {
        let store = EphemeralCredentialStore()

        XCTAssertNil(try await store.credential(for: key))

        try await store.setCredential("a-secret", for: key)
        XCTAssertEqual(try await store.credential(for: key), "a-secret")
    }

    func testAnEmptyValueClearsRatherThanStoringBlank() async throws {
        let store = EphemeralCredentialStore()
        try await store.setCredential("a-secret", for: key)

        try await store.setCredential("", for: key)
        XCTAssertNil(try await store.credential(for: key))

        try await store.setCredential("a-secret", for: key)
        try await store.setCredential(nil, for: key)
        XCTAssertNil(try await store.credential(for: key))
    }

    func testRemoving() async throws {
        let store = EphemeralCredentialStore()
        try await store.setCredential("a-secret", for: key)

        try await store.removeCredential(for: key)
        XCTAssertNil(try await store.credential(for: key))

        // Removing something absent is not an error.
        try await store.removeCredential(for: key)
    }

    func testKeysAreScopedPerProvider() async throws {
        let store = EphemeralCredentialStore()
        let other = CredentialKey.remoteAIAPIKey(providerID: "remote.something-else")

        try await store.setCredential("first", for: key)
        try await store.setCredential("second", for: other)

        XCTAssertEqual(try await store.credential(for: key), "first")
        XCTAssertEqual(try await store.credential(for: other), "second")
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
