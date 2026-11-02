import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// MetisAI's own action model in the catalog, and what "action-only" means.
///
/// ## What is being protected
///
/// Metis Action 0.8B was fine-tuned to turn a bare sentence into one action.
/// Two things follow, and both were measured rather than assumed: it should be
/// given the sentence alone (73% → 85% right action on the golden set, see
/// `LocalModelPurpose`), and it is not a chat model — it answers everything
/// with an action — so no screen may offer it as the model you talk to.
final class MetisActionModelCatalogTests: XCTestCase {

    private static let metisID: AIModelIdentifier = "metis-action-0.8b-q4-k-m"

    private func shipped() throws -> LocalModelDescriptor {
        let catalog = LocalModelCatalog.bundled()
        try XCTSkipIf(catalog.models.isEmpty, "catalog resource unavailable in this runner")
        return try XCTUnwrap(
            catalog.descriptor(for: Self.metisID), "Metis Action is missing from the catalog"
        )
    }

    // MARK: The shipped entry is the file that was uploaded

    /// Size and SHA-256 are the GitHub release's own figures for the asset, so
    /// a download that is not byte-for-byte that file fails verification.
    func testTheShippedEntryIsTheUploadedFile() throws {
        let model = try shipped()
        XCTAssertEqual(model.purpose, .metisAction)
        XCTAssertEqual(model.architecture, "qwen35", "checked against the file's own header")
        XCTAssertEqual(model.quantization, .q4KM)
        XCTAssertEqual(model.parameterCount, 752_393_024)
        XCTAssertEqual(model.fileSizeBytes, 529_297_088)
        XCTAssertEqual(
            model.checksumSHA256,
            "e9ed51432be2140b93cd6232ef6b2aaddcecaf626d9a56020aacf4d07e10fa63"
        )
        XCTAssertEqual(model.downloadURL?.scheme, "https")
        XCTAssertEqual(model.downloadURL?.host, "github.com")
    }

    /// It is only ever opened by the action host, so its default is the action
    /// context, not a chat-sized one.
    func testItOpensWithTheActionContext() throws {
        let model = try shipped()
        XCTAssertEqual(
            model.defaultContextLength, ActionInferenceProductionPolicy.production.contextLength
        )
    }

    /// qwen35 is hybrid: 6 of its 24 layers are full attention and the rest are
    /// recurrent, so only those 6 keep a KV cache — 2 KV heads × (256 + 256)
    /// dims × 2 bytes each. A generic estimate would count all 24, four times
    /// too much.
    func testTheKVFigureCountsOnlyTheAttentionLayers() throws {
        let model = try shipped()
        XCTAssertEqual(model.kvCacheBytesPerToken, 6 * 2 * (256 + 256) * 2)
    }

    func testOnlyTheMetisEntryIsActionOnly() throws {
        let catalog = LocalModelCatalog.bundled()
        try XCTSkipIf(catalog.models.isEmpty, "catalog resource unavailable in this runner")
        let actionOnly = catalog.models.filter { !$0.purpose.isChatModel }.map(\.id)
        XCTAssertEqual(actionOnly, [Self.metisID])
    }

    // MARK: The field in the file

    /// The twelve entries written before this field existed must read exactly
    /// as they did.
    func testAnEntryThatDoesNotSayIsGeneral() throws {
        let json = """
            {"version":1,"models":[{"id":"tiny","displayName":"Tiny",\
            "architecture":"llama"}]}
            """
        let decoded = try LocalModelCatalog.decode(Data(json.utf8))
        let model = try XCTUnwrap(decoded.models.first)
        XCTAssertEqual(model.purpose, .general)
        XCTAssertTrue(model.purpose.isChatModel)
        XCTAssertFalse(model.purpose.expectsBareActionPrompt)
    }

    /// `general` is not written out, so existing entries round-trip to the JSON
    /// they were written as; `metisAction` is, and survives.
    func testThePurposeRoundTrips() throws {
        let general = LocalModelDescriptor(id: "g", displayName: "G", architecture: "llama")
        let generalData = try JSONCoding.encoder.encode(general)
        XCTAssertFalse(String(decoding: generalData, as: UTF8.self).contains("purpose"))
        let generalBack = try JSONCoding.decoder.decode(LocalModelDescriptor.self, from: generalData)
        XCTAssertEqual(generalBack.purpose, .general)

        let metis = LocalModelDescriptor(
            id: "m", displayName: "M", architecture: "qwen35", purpose: .metisAction
        )
        let metisData = try JSONCoding.encoder.encode(metis)
        let metisBack = try JSONCoding.decoder.decode(LocalModelDescriptor.self, from: metisData)
        XCTAssertEqual(metisBack.purpose, .metisAction)
    }

    // MARK: Never the chat model

    private func status(
        _ purpose: LocalModelPurpose, lifecycle: LocalModelLifecycle = .downloaded
    ) -> LocalModelStatus {
        LocalModelStatus(
            descriptor: LocalModelDescriptor(
                id: "m", displayName: "M", architecture: "qwen35", purpose: purpose
            ),
            lifecycle: lifecycle,
            compatibility: .compatible
        )
    }

    func testTheChatPickerNeverOffersAnActionOnlyModel() {
        XCTAssertTrue(AssistantLocalChoices.choices(from: [status(.metisAction)]).isEmpty)
        XCTAssertEqual(AssistantLocalChoices.choices(from: [status(.general)]).count, 1)
    }

    /// "Use for Chat" would make it the chat model, and Load on this screen
    /// loads into the *chat* runtime. The action model loads from its own
    /// screen; the row keeps Delete.
    func testItsRowOffersNeitherUseForChatNorAChatLoad() {
        let row = LocalModelRowPresenter.state(
            for: status(.metisAction), isDownloading: false, failure: nil
        )
        XCTAssertFalse(row.actions.contains(.use))
        XCTAssertFalse(row.actions.contains(.load))
        XCTAssertFalse(row.actions.contains(.retryLoad))
        XCTAssertTrue(row.actions.contains(.delete), "the file is still worth being able to remove")

        let general = LocalModelRowPresenter.state(
            for: status(.general), isDownloading: false, failure: nil
        )
        XCTAssertTrue(general.actions.contains(.use))
        XCTAssertTrue(general.actions.contains(.load))
    }

    /// Build 17 offered nothing in place of Use for Chat, so a downloaded
    /// Metis Action could not be put to use from the screen it was downloaded
    /// on.
    func testItsRowOffersUseForActionsUntilItIsTheActionModel() {
        let row = LocalModelRowPresenter.state(for: status(.metisAction))
        XCTAssertEqual(row.actions.first, .useForActions)

        let chosen = LocalModelRowPresenter.state(for: status(.metisAction), isActionModel: true)
        XCTAssertFalse(chosen.actions.contains(.useForActions))
        XCTAssertTrue(chosen.actions.contains(.delete))

        let notDownloaded = LocalModelRowPresenter.state(
            for: status(.metisAction, lifecycle: .notDownloaded)
        )
        XCTAssertFalse(notDownloaded.actions.contains(.useForActions))

        let general = LocalModelRowPresenter.state(for: status(.general))
        XCTAssertFalse(general.actions.contains(.useForActions))
    }

    // MARK: Compatibility

    /// Recognised on purpose, not because "qwen35" happens to begin with
    /// "qwen3".
    func testQwen35IsARecognisedActionFamily() {
        XCTAssertTrue(ActionModelCompatibilityResolver.supportedFamilies.contains("qwen35"))
    }
}
