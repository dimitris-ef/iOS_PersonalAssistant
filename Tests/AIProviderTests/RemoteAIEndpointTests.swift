import XCTest
@testable import AIProviderRemote

/// Endpoint normalisation is fiddly and easy to get subtly wrong, which is
/// exactly why it lives in its own type with its own tests.
final class RemoteAIEndpointTests: XCTestCase {
    func testAcceptsAPlainBaseURL() throws {
        let endpoint = try XCTUnwrap(RemoteAIEndpoint(baseURL: "https://api.example.com/v1"))
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testAssumesHTTPSForABareHost() throws {
        let endpoint = try XCTUnwrap(RemoteAIEndpoint(baseURL: "api.example.com/v1"))
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertFalse(endpoint.isInsecure)
    }

    func testDoesNotDuplicateTheVersionSegment() throws {
        // The bug this exists to prevent: /v1/v1/chat/completions.
        let withVersion = try XCTUnwrap(RemoteAIEndpoint(baseURL: "https://api.example.com/v1"))
        XCTAssertEqual(
            withVersion.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )

        let withoutVersion = try XCTUnwrap(RemoteAIEndpoint(baseURL: "https://api.example.com"))
        XCTAssertEqual(
            withoutVersion.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testIgnoresATrailingSlash() throws {
        let endpoint = try XCTUnwrap(RemoteAIEndpoint(baseURL: "https://api.example.com/v1///"))
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testToleratesTheFullChatCompletionsPath() throws {
        // People paste the URL from documentation.
        let endpoint = try XCTUnwrap(
            RemoteAIEndpoint(baseURL: "https://api.example.com/v1/chat/completions")
        )
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testRecognisesOtherVersionSegments() throws {
        let endpoint = try XCTUnwrap(RemoteAIEndpoint(baseURL: "https://example.com/openai/v2"))
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "https://example.com/openai/v2/chat/completions"
        )
    }

    func testAllowsLocalHTTPServers() throws {
        // Self-hosted inference servers are usually plaintext on a LAN, so
        // rejecting http outright would block a legitimate case.
        let endpoint = try XCTUnwrap(RemoteAIEndpoint(baseURL: "http://localhost:11434/v1"))
        XCTAssertTrue(endpoint.isInsecure)
        XCTAssertEqual(endpoint.host, "localhost")
        XCTAssertEqual(
            endpoint.chatCompletionsURL().absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
    }

    func testRejectsUnusableValues() {
        XCTAssertNil(RemoteAIEndpoint(baseURL: ""))
        XCTAssertNil(RemoteAIEndpoint(baseURL: "   "))
        XCTAssertNil(RemoteAIEndpoint(baseURL: "ftp://example.com"))
        XCTAssertNil(RemoteAIEndpoint(baseURL: "https://"))
    }
}

final class RemoteAIConfigurationTests: XCTestCase {
    func testReportsEveryMissingRequirementAtOnce() {
        let configuration = RemoteAIConfiguration(baseURL: "", model: "")
        let missing = configuration.missingRequirements(hasCredential: false)

        XCTAssertEqual(Set(missing), [.endpoint, .model, .apiKey])
    }

    func testReportsAnUnusableEndpointSeparatelyFromAMissingOne() {
        let configuration = RemoteAIConfiguration(baseURL: "ftp://nope", model: "m")
        let missing = configuration.missingRequirements(hasCredential: true)

        XCTAssertEqual(missing, [.validEndpoint])
    }

    func testIsCompleteWhenEverythingIsPresent() {
        let configuration = RemoteAIConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "some-model"
        )
        XCTAssertTrue(configuration.missingRequirements(hasCredential: true).isEmpty)
        XCTAssertEqual(configuration.displayHost, "api.example.com")
    }

    func testTheDescriptionListsWhatIsMissing() {
        let error = RemoteAIError.notConfigured(missing: [.endpoint, .apiKey])
        XCTAssertEqual(error.userFacingDescription, "Remote AI needs an endpoint and an API key.")
    }
}
