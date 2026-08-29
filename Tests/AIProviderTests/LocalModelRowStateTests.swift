import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// Which control appears for which state, and what the row says it is.
///
/// A table with a wrong answer in every cell, and every wrong answer is quiet:
/// a Load button on a model whose file is missing looks exactly like a Load
/// button on a model that will load. `iOS/` has no test target, which is why
/// this logic is in the package at all.
final class LocalModelRowStateTests: XCTestCase {

    // MARK: Fixtures

    private func descriptor(
        _ id: AIModelIdentifier = "model-a",
        bytes: Int64? = 1_200_000_000,
        quantization: LocalModelQuantization? = .q4KM,
        architecture: String = "qwen3",
        url: URL? = URL(string: "https://example.invalid/model.gguf")
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: "Model A",
            architecture: architecture,
            parameterCount: 1_700_000_000,
            quantization: quantization,
            format: .gguf,
            fileSizeBytes: bytes,
            downloadURL: url
        )
    }

    private func status(
        lifecycle: LocalModelLifecycle,
        compatibility: LocalModelCompatibility = .compatible,
        isSelected: Bool = false,
        installed: LocalModelRecord? = nil,
        descriptor override: LocalModelDescriptor? = nil
    ) -> LocalModelStatus {
        LocalModelStatus(
            descriptor: override ?? descriptor(),
            lifecycle: lifecycle,
            compatibility: compatibility,
            installed: installed,
            isSelected: isSelected
        )
    }

    private func state(
        _ status: LocalModelStatus,
        isDownloading: Bool = false,
        failure: LocalModelRowFailure? = nil
    ) -> LocalModelRowState {
        LocalModelRowPresenter.state(
            for: status, isDownloading: isDownloading, failure: failure
        )
    }

    // MARK: Downloaded is not loaded

    /// Sections 15, 16 and 39 in one assertion. This is the state the whole
    /// pass is about: a finished download is on disk and nothing more, and the
    /// row has to say both halves rather than one word that reads as ready.
    func testAFreshlyDownloadedModelSaysItIsNotLoaded() {
        let row = state(status(lifecycle: .downloaded))

        XCTAssertEqual(row.runtime, .downloadedNotLoaded)
        XCTAssertFalse(row.runtime.isResident)
        XCTAssertFalse(row.runtime.isError)
        XCTAssertTrue(row.runtime.label.contains("Downloaded"))
        XCTAssertTrue(
            row.runtime.label.lowercased().contains("not loaded"),
            "the label collapsed downloaded and loaded again: \(row.runtime.label)"
        )
    }

    /// Use and Load are different decisions and both are offered. Neither has
    /// happened on its own.
    func testADownloadedModelOffersUseLoadAndDelete() {
        let row = state(status(lifecycle: .downloaded))
        XCTAssertEqual(row.actions, [.use, .load, .delete])
    }

    /// The selected-but-cold case: no second "Use", because it is already the
    /// one that answers — but it is still not in memory.
    func testTheSelectedModelStillOffersLoadWhenItIsNotResident() {
        let row = state(status(lifecycle: .downloaded, isSelected: true))
        XCTAssertEqual(row.runtime, .downloadedNotLoaded)
        XCTAssertFalse(row.offers(.use))
        XCTAssertTrue(row.offers(.load))
    }

    // MARK: Loaded

    func testALoadedAndSelectedModelIsInUseAndOffersUnload() {
        let row = state(status(lifecycle: .loaded, isSelected: true))
        XCTAssertEqual(row.runtime, .inUse)
        XCTAssertTrue(row.runtime.isResident)
        XCTAssertEqual(row.actions, [.unload, .delete])
        XCTAssertFalse(row.offers(.load), "it is already loaded")
    }

    /// Resident but not chosen. Distinct from "in use" because it is the state
    /// after switching models in the picker without unloading, and a row that
    /// called it In Use would be claiming the wrong model answers.
    func testALoadedButUnselectedModelSaysSoAndCanBeChosen() {
        let row = state(status(lifecycle: .loaded, isSelected: false))
        XCTAssertEqual(row.runtime, .loadedNotInUse)
        XCTAssertEqual(row.actions, [.use, .unload, .delete])
    }

    // MARK: In flight

    func testATransferOffersOnlyCancel() {
        let row = state(status(lifecycle: .notDownloaded), isDownloading: true)
        XCTAssertEqual(row.runtime, .downloading)
        XCTAssertEqual(row.actions, [.cancelDownload])
    }

    /// The row believes this screen's own transfer over the manager's status,
    /// which is refreshed only after the download finishes.
    func testALiveTransferOutranksAStaleNotDownloadedStatus() {
        let row = state(status(lifecycle: .notDownloaded), isDownloading: true)
        XCTAssertFalse(
            row.offers(.download),
            "a Download button next to its own progress bar"
        )
    }

    func testNothingIsOfferedWhileTheRuntimeIsBusy() {
        for lifecycle in [LocalModelLifecycle.verifying, .loading, .unloading] {
            let row = state(status(lifecycle: lifecycle))
            XCTAssertTrue(
                row.actions.isEmpty,
                "\(lifecycle) offered \(row.actions.map(\.rawValue))"
            )
            XCTAssertTrue(row.runtime.isBusy)
        }
    }

    // MARK: Not here yet

    func testACatalogModelOffersDownload() {
        let row = state(status(lifecycle: .notDownloaded))
        XCTAssertEqual(row.runtime, .notOnDevice)
        XCTAssertEqual(row.actions, [.download])
    }

    /// Sections 8 and 12: a model that cannot run here has no Download button,
    /// because spending someone's data allowance to tell them something
    /// knowable beforehand is the failure the compatibility check exists for.
    func testAModelThisDeviceCannotRunOffersNothingToDownload() {
        let row = state(
            status(
                lifecycle: .notDownloaded,
                compatibility: .likelyTooLarge(reason: "Needs more memory than this iPhone has.")
            )
        )
        XCTAssertTrue(row.runtime.isError)
        XCTAssertEqual(row.runtime.detail, "Needs more memory than this iPhone has.")
        XCTAssertTrue(row.actions.isEmpty)
    }

    /// A file that is here but will not run keeps Delete, because it is
    /// occupying gigabytes and reclaiming them is the only useful thing left.
    func testAnInstalledModelThatCannotRunKeepsDeleteAndNothingElse() {
        let row = state(
            status(
                lifecycle: .downloaded,
                compatibility: .unsupportedArchitecture(reason: "This build cannot run mamba models.")
            )
        )
        XCTAssertEqual(row.actions, [.delete])
        XCTAssertFalse(row.offers(.load))
        XCTAssertFalse(row.offers(.use))
    }

    // MARK: Failure and retry

    /// Retry has to mean the thing that failed. Re-downloading two gigabytes
    /// because a *load* ran out of memory is the wrong repair, and an
    /// expensive one.
    func testALoadFailureOffersAnotherLoadNotAnotherDownload() {
        let row = state(
            status(lifecycle: .downloaded),
            failure: LocalModelRowFailure(kind: .load, message: "Not enough memory.")
        )
        XCTAssertEqual(row.runtime, .failed(reason: "Not enough memory."))
        XCTAssertTrue(row.offers(.retryLoad))
        XCTAssertFalse(row.offers(.retryDownload))
        XCTAssertTrue(row.offers(.delete))
    }

    func testADownloadFailureOffersAnotherDownload() {
        let row = state(
            status(lifecycle: .notDownloaded),
            failure: LocalModelRowFailure(kind: .download, message: "The connection dropped.")
        )
        XCTAssertTrue(row.offers(.retryDownload))
        XCTAssertFalse(row.offers(.download), "Retry replaces Download rather than joining it")
    }

    /// A record whose file has gone — a restore that dropped excluded-from-
    /// backup files. The bytes are what is missing, so the bytes are the fix.
    func testAMissingFileOffersTheDownloadAgain() {
        let row = state(
            status(lifecycle: .failed(reason: "The model file is missing. Download it again."))
        )
        XCTAssertTrue(row.runtime.isError)
        XCTAssertTrue(row.offers(.retryDownload))
        XCTAssertTrue(row.offers(.delete))
    }

    // MARK: What the row says about the file

    /// Section 42.
    func testTheRowReportsSizePrecisionAndFamily() {
        let row = state(status(lifecycle: .downloaded))
        XCTAssertNotNil(row.sizeLabel)
        XCTAssertEqual(row.precisionLabel, "Q4_K_M")
        XCTAssertEqual(row.familyLabel, "qwen3")
    }

    /// Section 41: unknown is left blank rather than guessed at.
    func testAnUnknownPrecisionIsAbsentRatherThanInvented() {
        let row = state(
            status(
                lifecycle: .notDownloaded,
                descriptor: descriptor(bytes: nil, quantization: nil)
            )
        )
        XCTAssertNil(row.precisionLabel)
        XCTAssertNil(row.sizeLabel)
    }

    /// The installed record wins over the catalog: it is the number of bytes
    /// actually on the device, and the catalog's figure is a claim about a file
    /// that may have been republished since.
    func testTheInstalledSizeIsPreferredOverTheCatalogClaim() {
        let record = LocalModelRecord(
            id: "model-a",
            relativePath: "model-a.gguf",
            fileSizeBytes: 999_000_000,
            checksumSHA256: nil,
            checksumWasDeclared: false,
            installedAt: Date(timeIntervalSince1970: 1_781_078_400),
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 4096
        )
        let row = state(status(lifecycle: .downloaded, installed: record))

        XCTAssertEqual(row.familyLabel, "qwen2", "the file's own architecture, not the catalog's")
        XCTAssertNotNil(row.sizeLabel)
        XCTAssertFalse(
            row.sizeLabel?.contains("1.2") ?? true,
            "the catalog's size was shown for an installed model: \(row.sizeLabel ?? "nil")"
        )
    }

    // MARK: Every action has words

    func testEveryActionHasAPlainTitleAndNoRuntimeJargon() {
        // Section 70: nothing in the UI requires knowing what a GGUF is.
        let forbidden = ["gguf", "kv", "quant", "tensor", "metal", "ubatch", "mmap"]
        for action in LocalModelAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            let lowered = action.title.lowercased()
            for word in forbidden {
                XCTAssertFalse(lowered.contains(word), "\(action.rawValue): \(action.title)")
            }
        }
        XCTAssertTrue(LocalModelAction.delete.isDestructive)
        XCTAssertFalse(LocalModelAction.load.isDestructive)
    }
}
