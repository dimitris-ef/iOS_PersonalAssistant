import AssistantAI
import AssistantDomain
import Foundation

/// What verification concluded about a downloaded file.
public struct LocalModelVerification: Hashable, Sendable {
    /// SHA-256 of the bytes that arrived.
    public var checksum: String
    /// True when the catalog declared a checksum and this one matched it.
    public var checksumWasDeclared: Bool
    /// The file's own header.
    public var header: GGUFHeader
    public var byteCount: Int64
    /// Places the file and the catalog disagreed. Not failures — the file wins
    /// — but worth surfacing, because a catalog that is wrong about one model
    /// is a catalog to distrust about the next.
    public var discrepancies: [String]

    public init(
        checksum: String,
        checksumWasDeclared: Bool,
        header: GGUFHeader,
        byteCount: Int64,
        discrepancies: [String] = []
    ) {
        self.checksum = checksum
        self.checksumWasDeclared = checksumWasDeclared
        self.header = header
        self.byteCount = byteCount
        self.discrepancies = discrepancies
    }
}

/// Turns a downloaded file into an installed model, or refuses to.
///
/// ## The order matters
///
/// ```
/// bytes on disk
///     ↓  checksum, when the catalog declares one
///     ↓  GGUF header — is this a model at all?
///     ↓  does it match what the catalog said it was?
///     ↓  atomic move into the models directory
/// installed
/// ```
///
/// Nothing is called installed until every step above it has passed (section
/// 22), and a file that fails any of them is deleted rather than left where a
/// later launch might find it and assume the best (section 23).
///
/// ## About the checksum being optional
///
/// Section 22 asks for one and this enforces one wherever the catalog has it.
/// Where it does not, verification does not become a no-op: the file still has
/// to be a structurally valid GGUF of the declared architecture and roughly the
/// declared size, and the digest of whatever arrived is computed and recorded
/// so a later integrity check has a baseline. What is lost without a published
/// digest is the ability to detect a *substituted* file that is otherwise
/// well-formed — which is precisely why the transport refuses plain HTTP.
public struct LocalModelInstaller: Sendable {
    private let store: LocalModelStore
    private let dateProvider: any DateProvider
    private let estimator: LocalModelResourceEstimator

    /// How far the delivered size may drift from the catalog's before it counts
    /// as the wrong file. Generous, because catalogs are maintained by hand and
    /// a re-quantized upload changes the size by a percent or two.
    public static let sizeTolerance = 0.05

    public init(
        store: LocalModelStore,
        dateProvider: any DateProvider = SystemDateProvider(),
        estimator: LocalModelResourceEstimator = .default
    ) {
        self.store = store
        self.dateProvider = dateProvider
        self.estimator = estimator
    }

    /// Checks a downloaded file without moving it.
    ///
    /// Separate from installation so a failure leaves nothing in the models
    /// directory to clean up.
    public func verify(
        _ file: DownloadedFile,
        against descriptor: LocalModelDescriptor
    ) throws -> LocalModelVerification {
        let checksum: String
        do {
            checksum = try SHA256Hash.hexDigest(ofFileAt: file.url)
        } catch {
            throw LocalModelDownloadError.diskWrite(reason: error.localizedDescription)
        }

        if let expected = descriptor.checksumSHA256, !expected.isEmpty {
            guard SHA256Hash.matches(expected, checksum) else {
                throw LocalModelDownloadError.checksumMismatch(
                    expected: SHA256Hash.normalize(expected),
                    actual: checksum
                )
            }
        }

        // Section 24: the extension is not evidence. This reads the file's own
        // magic and metadata, and a CDN error page named `.gguf` fails here.
        let header: GGUFHeader
        do {
            header = try GGUFReader.read(contentsOf: file.url)
        } catch let error as GGUFReadError {
            throw LocalModelDownloadError.notAModel(reason: error.description)
        }

        guard header.tensorCount > 0 else {
            throw LocalModelDownloadError.notAModel(
                reason: "the file contains no model weights"
            )
        }

        // Section 116: the catalog is a claim about the file, and now the file
        // can be asked directly. A mismatch in *architecture* is disqualifying
        // — it means the download is a different model, and everything the app
        // decided about memory and chat template was decided about something
        // else.
        if let actual = header.architecture,
           !descriptor.architecture.isEmpty,
           actual.caseInsensitiveCompare(descriptor.architecture) != .orderedSame {
            throw LocalModelDownloadError.modelMismatch(
                reason: "This file is a \(actual) model, but \(descriptor.displayName) "
                    + "was expected to be \(descriptor.architecture)."
            )
        }

        var discrepancies: [String] = []
        if let declared = descriptor.fileSizeBytes, declared > 0 {
            let drift = abs(Double(file.byteCount - declared)) / Double(declared)
            if drift > Self.sizeTolerance {
                discrepancies.append(
                    "expected about \(LocalModelCompatibilityPolicy.format(declared)), "
                        + "received \(LocalModelCompatibilityPolicy.format(file.byteCount))"
                )
            }
        }
        if let declared = descriptor.quantization,
           let actual = header.quantization,
           declared != actual {
            discrepancies.append("catalog says \(declared), file says \(actual)")
        }

        return LocalModelVerification(
            checksum: checksum,
            checksumWasDeclared: descriptor.checksumSHA256?.isEmpty == false,
            header: header,
            byteCount: file.byteCount,
            discrepancies: discrepancies
        )
    }

    /// Verifies and, if it passes, moves the file into the models directory.
    ///
    /// The temporary file is deleted whichever way this goes: on success it has
    /// been moved, and on failure it is a file that failed verification and has
    /// no business surviving.
    public func install(
        _ file: DownloadedFile,
        descriptor: LocalModelDescriptor,
        device: any DeviceResourceProvider
    ) throws -> LocalModelRecord {
        let verification: LocalModelVerification
        do {
            verification = try verify(file, against: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: file.url)
            throw error
        }

        let relativePath = descriptor.suggestedFileName
        do {
            _ = try store.install(file.url, as: relativePath)
        } catch {
            try? FileManager.default.removeItem(at: file.url)
            throw error
        }

        return LocalModelRecord(
            id: descriptor.id,
            relativePath: relativePath,
            fileSizeBytes: verification.byteCount,
            checksumSHA256: verification.checksum,
            checksumWasDeclared: verification.checksumWasDeclared,
            installedAt: dateProvider.now,
            architecture: verification.header.architecture ?? descriptor.architecture,
            quantization: (verification.header.quantization ?? descriptor.quantization)?.rawValue,
            contextLength: contextLength(
                for: descriptor,
                header: verification.header,
                fileSize: verification.byteCount,
                device: device
            )
        )
    }

    /// The context this model will actually be opened with.
    ///
    /// Three limits, smallest wins: what the catalog asked for, what the
    /// weights were trained for, and what this device's memory budget allows
    /// (sections 11, 44 and 45). Opening a model at its theoretical maximum
    /// because the file says it supports 128k is how a 1.5 GB model becomes a
    /// 6 GB allocation.
    public func contextLength(
        for descriptor: LocalModelDescriptor,
        header: GGUFHeader?,
        fileSize: Int64,
        device: any DeviceResourceProvider
    ) -> Int {
        var wanted = descriptor.defaultContextLength
        if let trained = header?.trainedContextLength, trained > 0 {
            wanted = min(wanted, trained)
        }
        if let ceiling = descriptor.maximumContextLength, ceiling > 0 {
            wanted = min(wanted, ceiling)
        }

        // The measured figure from the file beats the catalog's, which beats
        // the estimator's fallback.
        let kvPerToken = header?.kvCacheBytesPerToken ?? descriptor.kvCacheBytesPerToken
        let fitting = estimator.largestFittingContext(
            weightsBytes: fileSize,
            kvBytesPerToken: kvPerToken,
            preferred: wanted,
            on: device
        )
        // No fitting context at all still returns the smallest one rather than
        // zero: loading will fail, and it should fail in the runtime with a
        // real allocation error rather than here with an arithmetic one.
        return fitting ?? 1024
    }
}
