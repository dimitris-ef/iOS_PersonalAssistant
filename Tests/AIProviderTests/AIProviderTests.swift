import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderApple
@testable import AIProviderLocal
@testable import AIProviderRemote

final class ProviderStubTests: XCTestCase {
    func testAppleProviderReportsUnavailableAndRefusesToFabricateOutput() async throws {
        let provider = AppleFoundationModelsProvider()

        XCTAssertEqual(provider.metadata.kind, .appleFoundationModels)
        XCTAssertFalse(provider.metadata.requiresNetwork)

        let availability = await provider.availability()
        XCTAssertFalse(availability.isAvailable)

        do {
            _ = try await provider.respond(
                to: AIRequest(systemPrompt: "", messages: [AIMessage(role: .user, content: "hi")])
            )
            XCTFail("The unimplemented Apple provider must throw, never return a fake answer")
        } catch let error as AIProviderError {
            guard case .notImplemented = error else {
                return XCTFail("Expected .notImplemented, got \(error)")
            }
        }
    }

    func testLocalProviderIsUnavailableUntilARuntimeIsChosen() async throws {
        let provider = LocalModelProvider(
            catalog: LocalModelCatalog(descriptors: [
                LocalModelDescriptor(
                    id: "example.model",
                    displayName: "Example",
                    format: .gguf
                )
            ])
        )

        let availability = await provider.availability()
        guard case .unavailable(let reason) = availability else {
            return XCTFail("Expected unavailable without a runtime")
        }
        XCTAssertTrue(reason.contains("runtime"))

        // Model metadata is still browsable, so a download UI can be built now.
        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.id), ["example.model"])
        XCTAssertTrue(models.allSatisfy(\.isOnDevice))
    }

    func testLocalProviderUsesWhateverRuntimeIsInjected() async throws {
        let runtime = StubLocalRuntime()
        let descriptor = LocalModelDescriptor(id: "example.model", displayName: "Example", format: .mlx)
        let provider = LocalModelProvider(
            catalog: LocalModelCatalog(descriptors: [descriptor]),
            runtime: runtime,
            defaultModelID: descriptor.id
        )

        let availability = await provider.availability()
        XCTAssertTrue(availability.isAvailable)

        let response = try await provider.respond(
            to: AIRequest(systemPrompt: "", messages: [AIMessage(role: .user, content: "hi")])
        )
        XCTAssertEqual(response.text, "from the stub runtime")
    }

    func testRemoteProviderIsUnavailableWithoutACredential() async {
        let provider = RemoteAIProvider(
            adapter: StubRemoteAdapter(),
            transport: StubTransport(response: HTTPResponse(statusCode: 200, body: Data())),
            credentials: StubCredentials(credential: nil)
        )

        let availability = await provider.availability()
        XCTAssertFalse(availability.isAvailable)
    }

    func testRemoteProviderDelegatesEncodingAndParsingToItsAdapter() async throws {
        let adapter = StubRemoteAdapter()
        let transport = StubTransport(
            response: HTTPResponse(statusCode: 200, body: Data("ok".utf8))
        )
        let provider = RemoteAIProvider(
            adapter: adapter,
            transport: transport,
            credentials: StubCredentials(credential: "secret")
        )

        let response = try await provider.respond(
            to: AIRequest(systemPrompt: "sys", messages: [AIMessage(role: .user, content: "hi")])
        )

        XCTAssertEqual(response.text, "parsed by the adapter")
        XCTAssertEqual(response.providerID, adapter.providerID)
        let sent = try XCTUnwrap(transport.sentRequests.last)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer secret")
    }

    func testRemoteProviderSurfacesHTTPFailures() async {
        let provider = RemoteAIProvider(
            adapter: StubRemoteAdapter(),
            transport: StubTransport(
                response: HTTPResponse(statusCode: 500, body: Data("boom".utf8))
            ),
            credentials: StubCredentials(credential: "secret")
        )

        do {
            _ = try await provider.respond(to: AIRequest(systemPrompt: "", messages: []))
            XCTFail("Expected an error for a 500 response")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialsAreNeverReadFromSource() async {
        // The default provider reads an environment variable derived from the
        // provider id; nothing is baked into the binary.
        let credentials = EnvironmentCredentialProvider(prefix: "ASSISTANT_TEST_KEY_")
        let value = await credentials.credential(for: "remote.example")
        XCTAssertNil(value)
    }
}

// MARK: - Stubs

private struct StubLocalRuntime: LocalModelRuntime {
    var supportedFormats: [LocalModelFormat] { [.mlx, .gguf] }

    func state(of model: LocalModelDescriptor) async -> LocalModelState { .ready }
    func load(_ model: LocalModelDescriptor) async throws {}
    func unload(_ model: LocalModelDescriptor) async {}

    func generate(_ request: AIRequest, model: LocalModelDescriptor) async throws -> AIResponse {
        AIResponse(text: "from the stub runtime", providerID: LocalModelProvider.providerID)
    }
}

private struct StubRemoteAdapter: RemoteAPIAdapter {
    var providerID: AIProviderIdentifier { "remote.stub" }
    var displayName: String { "Stub API" }
    var capabilityRank: Int { 90 }

    func availableModels() async throws -> [AIModel] {
        [
            AIModel(
                id: "remote.stub.model",
                displayName: "Stub model",
                supportsNativeToolCalling: true,
                isOnDevice: false
            )
        ]
    }

    func makeRequest(from request: AIRequest, credential: String) throws -> HTTPRequest {
        HTTPRequest(
            url: URL(string: "https://example.invalid/v1/messages")!,
            headers: ["Authorization": "Bearer \(credential)"],
            body: Data()
        )
    }

    func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse {
        AIResponse(text: "parsed by the adapter", providerID: providerID)
    }
}

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    private(set) var sentRequests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sentRequests.append(request)
        return response
    }
}

private struct StubCredentials: CredentialProvider {
    let value: String?

    init(credential: String?) { self.value = credential }

    func credential(for providerID: AIProviderIdentifier) async -> String? { value }
}
