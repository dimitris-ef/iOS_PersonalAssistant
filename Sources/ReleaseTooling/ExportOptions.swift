import Foundation

/// The plist `xcodebuild -exportArchive` is driven by.
///
/// ## Why it is generated rather than committed
///
/// The file has to name three provisioning profiles, and their names come from
/// the profiles themselves — decoded at build time from secrets. A committed
/// ExportOptions.plist would therefore either hardcode names that go stale the
/// first time a certificate is renewed, or be a template with placeholders that
/// something has to substitute anyway. Generating it from values already read
/// out of the profiles removes both.
///
/// ## What is deliberately absent
///
/// Part 14, section 62. No certificate password, no API key, no decoded
/// certificate, no profile contents. Every field below is a name, an identifier
/// or an enumeration value — the file is safe to print, and the workflow does
/// print it, because an export failure is otherwise very hard to diagnose.
///
/// `signingCertificate` is the *name* of a certificate class, not a certificate.
/// `teamID` is a public identifier that appears in every app's bundle.
public struct ExportOptions: Equatable, Sendable {

    /// How the archive is being distributed.
    ///
    /// `app-store-connect` is the current spelling. Xcode 15 and earlier used
    /// `app-store`, and both are accepted by Xcode 16 and 26 — but the older
    /// name emits a deprecation warning that reads like an error in a CI log.
    public enum Method: String, Equatable, Sendable {
        case appStoreConnect = "app-store-connect"
        case release = "release-testing"
        case development
    }

    public let method: Method
    public let teamID: String
    /// Bundle identifier → provisioning profile *name*.
    public let provisioningProfiles: [String: String]
    /// Whether to upload the debug symbols with the build.
    ///
    /// True: without dSYMs, every crash report from a tester is a hex address.
    /// The app ships no third-party crash reporter, so App Store Connect's
    /// symbolication is the only thing standing between a tester's crash and a
    /// stack trace nobody can read.
    public let uploadSymbols: Bool
    /// False. Bitcode has been removed from the toolchain entirely; leaving the
    /// key out lets a future Xcode default it back on.
    public let uploadBitcode: Bool
    /// Manual. The runner has no Xcode account to fetch a profile with, and a
    /// build that silently regenerates its own profiles is a build whose
    /// entitlements nobody reviewed.
    public let signingStyle: String
    public let signingCertificate: String
    /// Whether to strip Swift symbols from the binary.
    ///
    /// False, for the same reason `uploadSymbols` is true.
    public let stripSwiftSymbols: Bool

    public init(
        method: Method = .appStoreConnect,
        teamID: String,
        provisioningProfiles: [String: String],
        uploadSymbols: Bool = true,
        uploadBitcode: Bool = false,
        signingStyle: String = "manual",
        signingCertificate: String = "Apple Distribution",
        stripSwiftSymbols: Bool = false
    ) {
        self.method = method
        self.teamID = teamID
        self.provisioningProfiles = provisioningProfiles
        self.uploadSymbols = uploadSymbols
        self.uploadBitcode = uploadBitcode
        self.signingStyle = signingStyle
        self.signingCertificate = signingCertificate
        self.stripSwiftSymbols = stripSwiftSymbols
    }

    /// The full shipping configuration, given the three profile names.
    ///
    /// Takes names rather than reading them from anywhere, so that the mapping
    /// between a bundle identifier and its profile is built in one expression
    /// and cannot be half-filled.
    public static func appStore(
        teamID: String,
        mainProfile: String,
        widgetsProfile: String,
        keyboardProfile: String
    ) -> ExportOptions {
        ExportOptions(
            teamID: teamID,
            provisioningProfiles: [
                DistributionIdentifiers.appBundleID: mainProfile,
                DistributionIdentifiers.widgetsBundleID: widgetsProfile,
                DistributionIdentifiers.keyboardBundleID: keyboardProfile,
            ]
        )
    }

    /// The dictionary `xcodebuild` reads.
    public var dictionary: [String: Any] {
        [
            "method": method.rawValue,
            "teamID": teamID,
            "provisioningProfiles": provisioningProfiles,
            "uploadSymbols": uploadSymbols,
            "uploadBitcode": uploadBitcode,
            "signingStyle": signingStyle,
            "signingCertificate": signingCertificate,
            "stripSwiftSymbols": stripSwiftSymbols,
            // Never. Xcode's "manage version and build number" would rewrite the
            // build number the archive was already signed with, so the binary
            // App Store Connect receives would not be the one that was verified.
            "manageAppVersionAndBuildNumber": false,
        ]
    }

    /// Serialised as XML, which is what `xcodebuild` expects and what a human
    /// reading the CI log can check.
    public func serialized() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0
        )
    }

    /// Every reason this configuration would not export the archive we built.
    ///
    /// An export runs for minutes and fails with `exportArchive: No signing
    /// certificate "iOS Distribution" found`, which names neither the target nor
    /// the missing profile. These checks are cheaper and say which one.
    public func problems() -> [String] {
        var problems: [String] = []

        if teamID.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The signing team identifier is empty.")
        }

        for identifier in DistributionIdentifiers.allBundleIDs {
            guard let profile = provisioningProfiles[identifier] else {
                problems.append(
                    "ExportOptions has no provisioning profile for one of the three "
                        + "bundles in the archive."
                )
                continue
            }
            if profile.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(
                    "One of the provisioning profile names in ExportOptions is empty. "
                        + "The profile was probably decoded but not read."
                )
            }
        }

        if provisioningProfiles.count != DistributionIdentifiers.allBundleIDs.count {
            problems.append(
                "ExportOptions maps \(provisioningProfiles.count) profiles; the archive "
                    + "contains \(DistributionIdentifiers.allBundleIDs.count) bundles that "
                    + "each need one."
            )
        }

        if signingStyle != "manual" {
            problems.append(
                "ExportOptions uses '\(signingStyle)' signing. A headless runner has no "
                    + "account to fetch profiles with; signing must be manual."
            )
        }

        return problems
    }
}
