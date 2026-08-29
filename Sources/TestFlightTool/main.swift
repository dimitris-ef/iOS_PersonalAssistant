import Foundation
import ReleaseTooling

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The command line the deploy workflow drives.
///
/// ## Why the release logic is Swift and not shell
///
/// Everything this tool does could be written as `plutil`, `jq` and `grep` in
/// the workflow, and the first draft of most deploy pipelines is. The reason it
/// is not: none of that is testable. A repository whose only compiler is CI
/// cannot check a shell pipeline before running it, so a mistake in profile
/// parsing or in the build-number format is found by a forty-minute job
/// failing — or, worse, by a job succeeding on the wrong build.
///
/// Written as a package target, the same logic is compiled by the Swift Tests
/// workflow on every push and exercised by unit tests against fixtures. What
/// remains in the workflow is what genuinely needs the system: `security`,
/// `xcodebuild`, `codesign`, `altool`.
///
/// ## Secrets
///
/// Credentials are read from the environment, never from arguments: process
/// arguments are visible to every other process on the machine via `ps`, and
/// they end up in `xtrace` output. Nothing here prints a key, a token, an
/// issuer identifier or the contents of a profile — the subcommands emit
/// names, states and identifiers, and their whole output is expected to be
/// readable in a public build log.
///
/// This target is not a dependency of the app: it is absent from `project.yml`,
/// so no part of it can reach an iOS bundle (Part 14, section 109). That is a
/// property of the dependency graph, not a rule someone has to remember.

// MARK: - Output

/// Writes to stderr so that stdout stays parseable by the calling shell.
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("::error::" + message + "\n").utf8))
    exit(1)
}

func emit(_ line: String) {
    print(line)
}

// MARK: - Arguments

struct Arguments: Sendable {
    private let values: [String: String]
    private let positional: [String]

    init(_ raw: [String]) {
        var values: [String: String] = [:]
        var positional: [String] = []
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    values[name] = raw[index + 1]
                    index += 2
                } else {
                    values[name] = "true"
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
        self.values = values
        self.positional = positional
    }

    func optional(_ name: String) -> String? { values[name] }

    func required(_ name: String) -> String {
        guard let value = values[name], !value.isEmpty else {
            fail("Missing required argument --\(name).")
        }
        return value
    }

    func first() -> String {
        guard let value = positional.first else {
            fail("Missing required path argument.")
        }
        return value
    }

    func double(_ name: String, default fallback: Double) -> Double {
        guard let raw = values[name] else { return fallback }
        guard let value = Double(raw), value > 0 else {
            fail("--\(name) must be a positive number.")
        }
        return value
    }
}

/// A credential from the environment, or a refusal that names the variable
/// without printing anything it might hold.
func environment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fail("The environment variable \(name) is not set.")
    }
    return value
}

// MARK: - Subcommands

/// Prints the fields of a provisioning profile that are safe to log.
///
/// Shell-eval friendly, and quoted: profile names routinely contain spaces
/// ("MetisAI App Store 2026"), and an unquoted value would be split into words
/// by every shell that reads it.
func profileSummary(_ arguments: Arguments) throws {
    let path = arguments.first()
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let profile = try ProvisioningProfile.parse(data)

    emit("PROFILE_NAME=\(shellQuoted(profile.name))")
    emit("PROFILE_UUID=\(shellQuoted(profile.uuid))")
    emit("PROFILE_DISTRIBUTION=\(profile.distribution.rawValue)")
}

/// Validates a profile against what the target it signs actually needs.
func profileValidate(_ arguments: Arguments) throws {
    let path = arguments.first()
    let role = arguments.required("role")
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let profile = try ProvisioningProfile.parse(data)

    let expectation = ProvisioningProfile.Expectation(
        role: role,
        bundleIdentifier: arguments.required("bundle-id"),
        teamIdentifier: arguments.required("team"),
        applicationGroup: arguments.optional("app-group")
    )

    let problems = profile.problems(against: expectation)
    guard problems.isEmpty else {
        for problem in problems { note("::error::" + problem) }
        exit(1)
    }
    note("\(role) provisioning profile: \(profile.logSummary)")
}

/// Writes the ExportOptions.plist the export step is driven by.
func exportOptions(_ arguments: Arguments) throws {
    let options = ExportOptions.appStore(
        teamID: arguments.required("team"),
        mainProfile: arguments.required("main-profile"),
        widgetsProfile: arguments.required("widgets-profile"),
        keyboardProfile: arguments.required("keyboard-profile")
    )

    let problems = options.problems()
    guard problems.isEmpty else {
        for problem in problems { note("::error::" + problem) }
        exit(1)
    }

    let output = URL(fileURLWithPath: arguments.required("out"))
    try options.serialized().write(to: output, options: .atomic)
    note("Wrote export options for \(options.provisioningProfiles.count) bundles.")
}

/// Resolves the build number this run will sign into all three targets.
func buildNumber(_ arguments: Arguments) throws {
    let resolved = try BuildNumber.resolve(
        override: arguments.optional("override"),
        runNumber: arguments.required("run-number"),
        runAttempt: arguments.required("run-attempt")
    )
    emit(resolved)
}

/// Refuses to build if the shipping identifiers were never filled in.
func checkIdentifiers() {
    let problems = IdentifierPlaceholderCheck.problemsInShippingSet()
    guard problems.isEmpty else {
        for problem in problems { note("::error::" + problem) }
        exit(1)
    }
    note("Shipping identifiers are production values:")
    for identifier in DistributionIdentifiers.allBundleIDs { note("  \(identifier)") }
    note("  \(DistributionIdentifiers.appGroup)")
}

// MARK: - App Store Connect

/// Builds a token factory from the environment.
///
/// A closure rather than a token, because a poll can outlive a token's
/// twenty-minute ceiling and each request should carry a fresh one.
func tokenFactory() throws -> @Sendable () async throws -> String {
    #if canImport(CryptoKit)
    let keyID = environment("ASC_KEY_ID")
    let issuerID = environment("ASC_ISSUER_ID")
    let keyPath = environment("ASC_KEY_PATH")

    let pem: String
    do {
        pem = try String(contentsOfFile: keyPath, encoding: .utf8)
    } catch {
        fail("The App Store Connect private key could not be read from disk.")
    }
    let key = try AppStoreConnectToken.SigningKey(pem: pem)

    return {
        try AppStoreConnectToken.signed(
            claims: AppStoreConnectToken.Claims(issuerID: issuerID, keyID: keyID),
            key: key
        )
    }
    #else
    throw AppStoreConnectTokenError.cryptoUnavailable
    #endif
}

/// Confirms an app record exists before anything expensive happens.
func preflightApp(_ arguments: Arguments) async throws {
    let bundleID = arguments.optional("bundle-id") ?? DistributionIdentifiers.appBundleID
    let token = try tokenFactory()
    let poller = BuildProcessingPoller(transport: URLSessionAppStoreConnectTransport())

    let appID = try await poller.appID(forBundleID: bundleID, token: token())
    note("App Store Connect has a record for \(bundleID).")
    emit("ASC_APP_ID=\(appID)")
}

/// Waits for the exact build this run uploaded, and reports what happened to it.
///
/// The exit status is the milestone's own definition of success: zero only when
/// App Store Connect says `VALID` for this build number, and nothing else.
func pollBuild(_ arguments: Arguments) async throws {
    let bundleID = arguments.optional("bundle-id") ?? DistributionIdentifiers.appBundleID
    let target = arguments.required("build-number")
    let deadline = arguments.double("deadline", default: 45 * 60)
    let interval = arguments.double("interval", default: 30)

    let token = try tokenFactory()
    let poller = BuildProcessingPoller(transport: URLSessionAppStoreConnectTransport())
    let appID = try await poller.appID(forBundleID: bundleID, token: token())

    note("Waiting for build \(target) of \(bundleID) to finish processing.")

    let outcome = try await poller.wait(
        appID: appID,
        buildNumber: target,
        token: token,
        deadline: deadline,
        interval: interval,
        sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onPoll: { record in
            if let record {
                note("  build \(record.version): \(record.processingState.rawValue)")
            } else {
                note("  build \(target) has not appeared in App Store Connect yet.")
            }
        }
    )

    switch outcome {
    case .settled(let record) where record.processingState.isSuccess:
        emit("BUILD_ID=\(record.id)")
        emit("BUILD_VERSION=\(record.version)")
        emit("BUILD_STATE=\(record.processingState.rawValue)")
        note("Build \(record.version) is VALID and available in TestFlight.")

    case .settled(let record):
        fail(
            "Build \(record.version) finished processing in state "
                + "\(record.processingState.rawValue). It will not appear in TestFlight; "
                + "the failure detail is in App Store Connect and in the email Apple sends "
                + "to the account holder."
        )

    case .stillProcessing(let record):
        fail(
            "Build \(record.version) was still PROCESSING when this job's deadline passed. "
                + "The upload succeeded, but this run cannot confirm the build is usable."
        )

    case .neverAppeared:
        fail(
            "Build \(target) never appeared in App Store Connect. The upload reported "
                + "success, so either processing has not started or the binary was "
                + "rejected before a build record was created."
        )
    }
}

// MARK: - Helpers

/// Single-quotes a value for a POSIX shell, escaping any embedded quote.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Entry point

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
    note(
        """
        Usage: testflight-tool <command> [options]

          check-identifiers
          profile-summary  <profile>
          profile-validate <profile> --role R --bundle-id B --team T [--app-group G]
          export-options   --out P --team T --main-profile N --widgets-profile N \
        --keyboard-profile N
          build-number     --run-number N --run-attempt A [--override V]
          preflight-app    [--bundle-id B]
          poll-build       --build-number V [--bundle-id B] [--deadline S] [--interval S]

        App Store Connect credentials are read from ASC_KEY_ID, ASC_ISSUER_ID and
        ASC_KEY_PATH, never from arguments.
        """
    )
    exit(2)
}

let arguments = Arguments(Array(raw.dropFirst()))

do {
    switch command {
    case "check-identifiers":
        checkIdentifiers()
    case "profile-summary":
        try profileSummary(arguments)
    case "profile-validate":
        try profileValidate(arguments)
    case "export-options":
        try exportOptions(arguments)
    case "build-number":
        try buildNumber(arguments)
    case "preflight-app":
        // A blocking bridge, because a `main.swift` top level cannot be async
        // in Swift 5 language mode and this target deliberately has no
        // dependencies to borrow an async entry point from.
        try runBlocking { try await preflightApp(arguments) }
    case "poll-build":
        try runBlocking { try await pollBuild(arguments) }
    default:
        fail("Unknown command '\(command)'.")
    }
} catch {
    // Every error type in `ReleaseTooling` is `CustomStringConvertible`, so
    // interpolation gives the sentence written for a human rather than the
    // enum case. A Foundation error falls back to its own description, which is
    // still better than a raw case name.
    fail("\(error)")
}

/// Carries a result out of a detached task.
///
/// A local `var` captured by a `@Sendable` closure is a data race the compiler
/// is right to complain about; a reference type with the same lifetime as the
/// `wait` below is not, because only one side ever touches it at a time.
final class ErrorBox: @unchecked Sendable {
    var error: (any Error)?
}

/// Runs an async operation from a synchronous entry point.
///
/// `exit()` from inside the task would skip the semaphore and leave the process
/// hanging, so the failure is carried back out and rethrown on the calling
/// thread instead.
func runBlocking(_ operation: @escaping @Sendable () async throws -> Void) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ErrorBox()
    Task {
        do { try await operation() } catch { box.error = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = box.error { throw error }
}
