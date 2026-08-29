import Foundation

/// The build number an upload is identified by.
///
/// ## Why this is not just an incrementing integer
///
/// App Store Connect treats `CFBundleVersion` as the primary key of a build
/// within a marketing version. Upload a number it has already seen and the
/// upload is rejected outright — after the archive, after the export, after the
/// transfer. There is no way to replace a build, only to supersede it.
///
/// `GITHUB_RUN_NUMBER` is monotonically increasing per workflow and never
/// reused, which makes it exactly the right source. `GITHUB_RUN_ATTEMPT` is the
/// missing half: re-running a failed job reuses the run number, so a deploy that
/// failed *after* uploading and is then re-run would collide with itself. The
/// two together, as `run.attempt`, are unique across every execution GitHub can
/// produce.
///
/// The dotted form is deliberate. `CFBundleVersion` allows up to three
/// period-separated integers, so `412.2` is valid, sorts correctly against
/// `412.1`, and stays legible: a tester reporting a problem with "412.2" can be
/// pointed at exactly one workflow run.
public enum BuildNumber {

    /// Builds the number for a run, or explains why the inputs cannot make one.
    public static func make(runNumber: String, runAttempt: String) throws -> String {
        guard let run = positiveInteger(runNumber) else {
            throw BuildNumberError.invalidRunNumber
        }
        guard let attempt = positiveInteger(runAttempt) else {
            throw BuildNumberError.invalidRunAttempt
        }
        return "\(run).\(attempt)"
    }

    /// Validates a manually supplied build number.
    ///
    /// The workflow accepts an override for the one case that genuinely needs
    /// one: a run whose upload succeeded and whose *polling* failed, which must
    /// be re-attempted against the build number already in App Store Connect
    /// rather than a new one.
    ///
    /// It is validated rather than trusted, because an override goes straight
    /// into a signed binary. A value with a space in it produces an archive
    /// whose Info.plist is subtly wrong; a value with a shell metacharacter goes
    /// on an `xcodebuild` command line.
    public static func validate(override: String) throws -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BuildNumberError.emptyOverride }

        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else {
            throw BuildNumberError.malformedOverride(
                "must be one to three period-separated integers"
            )
        }
        for component in components {
            guard let value = positiveInteger(String(component)) else {
                throw BuildNumberError.malformedOverride(
                    "every component must be a non-negative integer with no leading zeros"
                )
            }
            // Apple's documented ceiling for a CFBundleVersion component.
            guard value <= 99_999 else {
                throw BuildNumberError.malformedOverride("each component must be 99999 or less")
            }
        }
        return trimmed
    }

    /// Resolves the build number for a run: the override when one was given and
    /// is valid, the run-derived value otherwise.
    public static func resolve(
        override: String?,
        runNumber: String,
        runAttempt: String
    ) throws -> String {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return try validate(override: override)
        }
        return try make(runNumber: runNumber, runAttempt: runAttempt)
    }

    /// A non-negative integer with no leading zeros, no sign and no whitespace.
    ///
    /// `Int(_:)` alone would accept " 12", "+12" and "007"; the first two break
    /// on a command line and the last compares wrong in App Store Connect,
    /// where `007` and `7` are the same build.
    private static func positiveInteger(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
            return nil
        }
        if text.count > 1 && text.hasPrefix("0") { return nil }
        return Int(text)
    }
}

public enum BuildNumberError: Error, Equatable, CustomStringConvertible {
    case invalidRunNumber
    case invalidRunAttempt
    case emptyOverride
    case malformedOverride(String)

    public var description: String {
        switch self {
        case .invalidRunNumber:
            return "GITHUB_RUN_NUMBER is not a positive integer."
        case .invalidRunAttempt:
            return "GITHUB_RUN_ATTEMPT is not a positive integer."
        case .emptyOverride:
            return "The supplied build number is empty."
        case .malformedOverride(let reason):
            return "The supplied build number is not a valid CFBundleVersion: \(reason)."
        }
    }
}

/// The marketing version, checked rather than generated.
///
/// Part 14, section 34: the existing `MARKETING_VERSION` is preserved, not
/// replaced. What this adds is the check that it is a shape App Store Connect
/// accepts — one to three integers — because a value it refuses is discovered
/// only at upload.
public enum MarketingVersion {
    public static func validate(_ version: String) throws -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else {
            throw MarketingVersionError.malformed(trimmed)
        }
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw MarketingVersionError.malformed(trimmed)
            }
        }
        return trimmed
    }
}

public enum MarketingVersionError: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let version):
            return "MARKETING_VERSION '\(version)' is not one to three period-separated "
                + "integers, which is what CFBundleShortVersionString requires."
        }
    }
}
