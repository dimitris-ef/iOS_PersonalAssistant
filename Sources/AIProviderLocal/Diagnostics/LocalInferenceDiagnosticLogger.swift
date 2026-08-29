import Foundation

/// What the inference pipeline calls to leave a breadcrumb.
///
/// A protocol so that ``LlamaCppRuntime`` never contains file-writing code
/// (section 1), and so tests can observe the exact sequence a run produced
/// without touching a disk.
public protocol LocalInferenceDiagnosticSink: AnyObject, Sendable {

    /// Whether the caller should bother assembling verbose metadata.
    ///
    /// Checked before building a progress line, so the cost of a suppressed
    /// event is one boolean read rather than a dictionary the sink discards.
    var isVerbose: Bool { get }

    /// Records an ordinary event. Cheap; may be buffered.
    func record(
        _ name: LocalInferenceEventName,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage?,
        metadata: LocalInferenceMetadata
    )

    /// Persists an ENTER **before returning**, and hands back the identifier
    /// its EXIT must quote.
    ///
    /// Section 7: the breadcrumb has to be on disk before the native call
    /// starts, so this is synchronous all the way down. Nothing about it is
    /// asynchronous, nothing about it is deferred, and nothing about it hops to
    /// another executor.
    func criticalEnter(
        _ stage: LocalInferenceStage,
        metadata: LocalInferenceMetadata
    ) -> LocalInferenceOperationID

    /// Persists an EXIT for an operation that returned.
    func criticalExit(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    )

    /// Persists a failure for an operation that returned an error.
    ///
    /// Distinct from `criticalExit` on purpose: a stage that threw *did* come
    /// back, so it is resolved and must not be reported as the place the
    /// process died — but it is not a success either.
    func criticalFailure(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    )
}

extension LocalInferenceDiagnosticSink {
    /// The common shape: an INFO line with a name and some metadata.
    public func info(
        _ name: LocalInferenceEventName,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage? = nil,
        metadata: LocalInferenceMetadata = .empty
    ) {
        record(
            name, type: .info, level: .info, category: category,
            stage: stage, metadata: metadata
        )
    }

    public func problem(
        _ name: LocalInferenceEventName,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage? = nil,
        metadata: LocalInferenceMetadata = .empty
    ) {
        record(
            name, type: .error, level: .error, category: category,
            stage: stage, metadata: metadata
        )
    }

    /// A verbose-only line. Suppressed entirely when verbose logging is off,
    /// including the cost of building its metadata.
    public func verbose(
        _ name: LocalInferenceEventName,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage? = nil,
        metadata: @autoclosure () -> LocalInferenceMetadata = .empty
    ) {
        guard isVerbose else { return }
        record(
            name, type: .info, level: .debug, category: category,
            stage: stage, metadata: metadata()
        )
    }
}

/// A sink that discards everything.
///
/// The default wherever a logger has not been injected, so no call site needs
/// to branch on whether diagnostics exist.
public final class NullLocalInferenceDiagnosticSink: LocalInferenceDiagnosticSink {
    public init() {}
    public var isVerbose: Bool { false }
    public func record(
        _ name: LocalInferenceEventName,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage?,
        metadata: LocalInferenceMetadata
    ) {}
    public func criticalEnter(
        _ stage: LocalInferenceStage, metadata: LocalInferenceMetadata
    ) -> LocalInferenceOperationID { LocalInferenceOperationID() }
    public func criticalExit(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {}
    public func criticalFailure(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {}
}

/// The real logger.
///
/// ## Why a lock and not an actor
///
/// An actor would be the idiomatic choice for "serialize access to mutable
/// state", and it is the wrong one here. Every actor call is `await`, and
/// `await` means the ENTER is *scheduled* rather than written — the calling
/// task suspends, and the native call that may kill the process happens on
/// whichever side of that suspension the scheduler chooses. Section 7 rules
/// that out explicitly.
///
/// ``LlamaCppRuntime`` is itself an actor, so a synchronous, lock-guarded
/// logger is also the only shape that can be called from inside it without a
/// second isolation domain to deadlock against (section 9). The lock is held
/// for a `write(2)` and nothing else — no reentrancy, no callbacks out, no
/// waiting on another queue.
///
/// ## What is always on, and what is not
///
/// Sections 67 and 68. Critical breadcrumbs, errors, session markers, the
/// launch record and configuration are written whatever the verbose setting is:
/// they are the crash trail, and a crash trail you have to have predicted to
/// switch on is not one. Verbose adds per-progress detail, which is noise
/// during normal use and gold while reproducing.
public final class LocalInferenceDiagnosticLogger: LocalInferenceDiagnosticSink, @unchecked Sendable {

    private let lock = NSLock()
    private let store: LocalInferenceDiagnosticStore
    private let writer: LocalInferenceFileWriter
    private let clock: () -> Date
    private let startedAt: Date
    /// Monotonic origin. `Date` can jump — a time-zone change or an NTP
    /// correction mid-generation would make elapsed times negative — so the
    /// elapsed column comes from a clock that only moves forwards.
    private let monotonicOrigin: DispatchTime

    public let appSessionID: LocalInferenceSessionID
    /// What the previous process left behind, resolved once at construction.
    public let recovery: LocalInferenceRecoverySummary?

    private var sequence = 0
    private var inferenceSessionID: LocalInferenceSessionID?
    private var verbose: Bool
    /// Open ENTERs in the order they were entered, so the sidecar can fall back
    /// to the innermost stage still running rather than to an arbitrary one.
    private var openOperations: [(id: LocalInferenceOperationID, stage: LocalInferenceStage)] = []

    public var isVerbose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return verbose
    }

    /// True when persistence has failed. Section 83 — surfaced, never thrown.
    public var writerDidFail: Bool { writer.hasFailed }
    public var writerFailureDescription: String? { writer.failureDescription }

    public init(
        store: LocalInferenceDiagnosticStore = .applicationSupport(),
        verbose: Bool = false,
        appSessionID: LocalInferenceSessionID = LocalInferenceSessionID(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.appSessionID = appSessionID
        self.verbose = verbose
        self.clock = clock
        self.startedAt = clock()
        self.monotonicOrigin = .now()

        try? store.prepareDirectory()
        // Read the previous session *before* opening this one's file, so the
        // recovery scan never sees a file this process is writing to.
        self.recovery = LocalInferenceSessionRecovery.recoverPreviousSession(
            in: store, excluding: appSessionID
        )
        self.writer = LocalInferenceFileWriter(url: store.url(forSession: appSessionID))

        // Rotation runs at startup rather than on a timer, and protects the
        // session just recovered: it is the evidence, and deleting it on the
        // launch that reads it would be the one unforgivable bug here.
        store.rotate(keeping: appSessionID, protecting: recovery?.sessionID)
    }

    // MARK: Session lifecycle

    /// Opens the session. Writes the marker every later launch looks for.
    public func startSession(metadata: LocalInferenceMetadata) {
        write(
            name: .sessionStart, type: .state, level: .info, category: .lifecycle,
            stage: nil, operation: nil, metadata: metadata, synchronize: true
        )
    }

    /// Records a clean shutdown.
    ///
    /// Section 93: iOS frequently kills an app without delivering any
    /// termination callback, so the *absence* of this marker means "no clean
    /// shutdown was recorded", not "the app crashed". The recovery wording is
    /// careful about that difference and so is this comment.
    public func endSession(clean: Bool, reason: String? = nil) {
        write(
            name: .sessionEnd, type: .state, level: .info, category: .lifecycle,
            stage: nil, operation: nil,
            metadata: LocalInferenceMetadata()
                .setting(.clean, clean)
                .setting(.reason, ifPresent: reason),
            synchronize: true
        )
        clearCurrentStage()
        writer.closeFile()
    }

    /// Starts a diagnostic session for one attempted generation (section 98).
    @discardableResult
    public func beginInferenceSession(metadata: LocalInferenceMetadata) -> LocalInferenceSessionID {
        let id = LocalInferenceSessionID()
        lock.lock()
        inferenceSessionID = id
        lock.unlock()
        write(
            name: .inferenceSessionStart, type: .state, level: .info, category: .lifecycle,
            stage: nil, operation: nil, metadata: metadata, synchronize: true
        )
        return id
    }

    public func endInferenceSession(metadata: LocalInferenceMetadata = .empty) {
        write(
            name: .inferenceSessionEnd, type: .state, level: .info, category: .lifecycle,
            stage: nil, operation: nil, metadata: metadata, synchronize: false
        )
        lock.lock()
        inferenceSessionID = nil
        lock.unlock()
    }

    public func setVerbose(_ enabled: Bool) {
        lock.lock()
        verbose = enabled
        lock.unlock()
    }

    // MARK: Sink

    public func record(
        _ name: LocalInferenceEventName,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage?,
        metadata: LocalInferenceMetadata
    ) {
        // Debug-level lines are the verbose tier. Everything else — info,
        // warning, error — is part of the trail and is written regardless.
        if level == .debug, !isVerbose { return }
        write(
            name: name, type: type, level: level, category: category,
            stage: stage, operation: nil, metadata: metadata,
            // Errors are flushed like breadcrumbs: an error immediately before
            // a termination is the most valuable line in the file.
            synchronize: level == .error
        )
    }

    public func criticalEnter(
        _ stage: LocalInferenceStage,
        metadata: LocalInferenceMetadata
    ) -> LocalInferenceOperationID {
        let operation = LocalInferenceOperationID()
        lock.lock()
        openOperations.append((operation, stage))
        lock.unlock()

        write(
            name: .stage, type: .enter, level: .info, category: .runtime,
            stage: stage, operation: operation, metadata: metadata, synchronize: true
        )
        // The sidecar, after the JSONL line. Ordering matters: if the process
        // dies between the two, the JSONL is still complete and recovery works
        // from it — the sidecar is the accelerator, never the record.
        writeCurrentStage(stage: stage, operation: operation)
        return operation
    }

    public func criticalExit(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {
        finish(
            stage, operation: operation, type: .exit, level: .info, metadata: metadata
        )
    }

    public func criticalFailure(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        metadata: LocalInferenceMetadata
    ) {
        finish(
            stage, operation: operation, type: .exit, level: .error,
            metadata: metadata.setting(.clean, false)
        )
    }

    private func finish(
        _ stage: LocalInferenceStage,
        operation: LocalInferenceOperationID,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        metadata: LocalInferenceMetadata
    ) {
        lock.lock()
        openOperations.removeAll { $0.id == operation }
        let stillOpen = openOperations.last
        lock.unlock()

        write(
            name: .stage, type: type, level: level, category: .runtime,
            stage: stage, operation: operation, metadata: metadata, synchronize: true
        )
        // Section 92: only clear the sidecar if it still names this operation.
        // A nested EXIT must not erase the outer stage that is still running.
        clearCurrentStage(ifOperationIs: operation, fallingBackTo: stillOpen)
    }

    // MARK: Writing

    private func write(
        name: LocalInferenceEventName,
        type: LocalInferenceEventType,
        level: LocalInferenceDiagnosticLevel,
        category: LocalInferenceDiagnosticCategory,
        stage: LocalInferenceStage?,
        operation: LocalInferenceOperationID?,
        metadata: LocalInferenceMetadata,
        synchronize: Bool
    ) {
        lock.lock()
        sequence += 1
        let event = LocalInferenceDiagnosticEvent(
            appSessionID: appSessionID,
            inferenceSessionID: inferenceSessionID,
            sequence: sequence,
            timestamp: clock(),
            elapsed: monotonicElapsed(),
            level: level,
            category: category,
            type: type,
            name: name,
            stage: stage,
            operationID: operation,
            metadata: metadata
        )
        let payload = LocalInferenceDiagnosticCoding.encode(event)
        // The lock is released before the syscall so a slow `fsync` does not
        // hold every other caller — the sequence number was already claimed
        // under it, which is what guarantees ordering (section 114). The writer
        // has its own lock and `O_APPEND` keeps the bytes contiguous.
        lock.unlock()

        // Section 83: the return value is deliberately dropped. A failed write
        // is recorded by the writer itself and read back through
        // `writerDidFail`, which the diagnostics screen shows. Reacting here —
        // retrying, throwing, logging the logging failure — would make the
        // diagnostic system a second way for inference to fail, which is the
        // one thing it must not become.
        _ = writer.append(payload, synchronize: synchronize)
    }

    private func monotonicElapsed() -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let origin = monotonicOrigin.uptimeNanoseconds
        guard now > origin else { return 0 }
        return TimeInterval(now - origin) / 1_000_000_000
    }

    // MARK: The last-stage sidecar

    /// Writes the open stage atomically (sections 91 and 92).
    ///
    /// A temporary file and a rename, so a reader never sees a half-written
    /// record: `rename(2)` on the same filesystem is atomic, which is the whole
    /// reason this is not written in place.
    private func writeCurrentStage(
        stage: LocalInferenceStage,
        operation: LocalInferenceOperationID
    ) {
        let object: [String: Any] = [
            "appSessionID": appSessionID.rawValue,
            "operationID": operation.rawValue,
            "stage": stage.rawValue,
            "eventType": LocalInferenceEventType.enter.rawValue,
            "sequence": currentSequence,
            "timestamp": LocalInferenceDiagnosticCoding.timestampFormatter.string(from: clock()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        let temporary = store.currentStageURL.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary, options: [.atomic])) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(store.currentStageURL, withItemAt: temporary)
    }

    private var currentSequence: Int {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    private func clearCurrentStage() {
        try? FileManager.default.removeItem(at: store.currentStageURL)
    }

    private func clearCurrentStage(
        ifOperationIs operation: LocalInferenceOperationID,
        fallingBackTo stillOpen: (id: LocalInferenceOperationID, stage: LocalInferenceStage)?
    ) {
        guard let sidecar = LocalInferenceSessionRecovery.readCurrentStage(in: store) else { return }
        guard sidecar.operationID == operation.rawValue else { return }
        // An enclosing stage is still open — name it, rather than leaving the
        // sidecar pointing at something that has finished. `generation_decode`
        // exiting inside `generation` should leave `generation` named.
        if let stillOpen {
            writeCurrentStage(stage: stillOpen.stage, operation: stillOpen.id)
        } else {
            clearCurrentStage()
        }
    }
}
