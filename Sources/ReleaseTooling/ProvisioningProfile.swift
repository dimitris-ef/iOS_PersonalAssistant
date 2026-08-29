import Foundation

/// What a `.mobileprovision` file actually says.
///
/// ## Why this is parsed rather than assumed
///
/// A provisioning profile is the single most common cause of a build that
/// compiles, archives, exports, uploads — and is then rejected, or installs and
/// silently loses a capability. Every failure mode is a mismatch between two
/// strings nobody looked at:
///
///   * the profile is for `…MetisAI` and the target builds `…MetisAI.widgets`
///   * the profile belongs to a different team than the certificate
///   * the profile grants no App Group, so the shared container resolves to nil
///     on a device and the widgets show a placeholder forever
///   * the profile expired three weeks ago
///   * the profile is a *development* profile, which archives happily and is
///     refused by App Store Connect after a twenty-minute upload
///
/// None of these produce a useful error at the point they are made. So the
/// deploy workflow decodes each profile, reads it with this type, and refuses
/// to start the archive when any of them is wrong — while the failure still
/// costs seconds instead of half an hour.
///
/// ## What is deliberately not here
///
/// The certificates. A profile embeds the DER of every certificate it trusts,
/// and there is no reason for this code to touch them: the keychain step
/// already proves the identity is importable and `codesign` proves it was used.
/// Reading fields that are never needed only creates opportunities to print
/// them.
public struct ProvisioningProfile: Equatable, Sendable {
    /// The profile's name in the developer portal — what
    /// `PROVISIONING_PROFILE_SPECIFIER` matches on.
    public let name: String
    /// The profile's UUID. Also its filename once installed.
    public let uuid: String
    /// The team the profile belongs to. Must match the signing certificate's.
    public let teamIdentifier: String
    /// The full `application-identifier` entitlement, team prefix included:
    /// `ABCDE12345.com.example.app`.
    public let applicationIdentifier: String
    public let expirationDate: Date?
    /// App Groups the profile grants. A bundle can only use a group that
    /// appears here, whatever its `.entitlements` file claims.
    public let applicationGroups: [String]
    /// True when the profile provisions every device in the team, which is what
    /// distinguishes an App Store or Enterprise profile from ad-hoc.
    public let provisionsAllDevices: Bool
    /// Present on development and ad-hoc profiles; absent on App Store ones.
    public let hasProvisionedDevices: Bool
    /// `get-task-allow`. True on development profiles, false on distribution
    /// ones — the most reliable discriminator Apple gives us.
    public let allowsDebugging: Bool

    public init(
        name: String,
        uuid: String,
        teamIdentifier: String,
        applicationIdentifier: String,
        expirationDate: Date?,
        applicationGroups: [String],
        provisionsAllDevices: Bool,
        hasProvisionedDevices: Bool,
        allowsDebugging: Bool
    ) {
        self.name = name
        self.uuid = uuid
        self.teamIdentifier = teamIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.expirationDate = expirationDate
        self.applicationGroups = applicationGroups
        self.provisionsAllDevices = provisionsAllDevices
        self.hasProvisionedDevices = hasProvisionedDevices
        self.allowsDebugging = allowsDebugging
    }

    /// The bundle identifier, with the team prefix stripped.
    ///
    /// Returns nil for a wildcard profile (`ABCDE12345.*` or
    /// `ABCDE12345.com.example.*`). That is not an oversight: a wildcard cannot
    /// carry an App Group or most other capabilities, so a nil here is the
    /// right way for `validate` to reject one.
    public var bundleIdentifier: String? {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return nil }
        let identifier = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        return identifier.contains("*") ? nil : identifier
    }

    /// How this profile may be used.
    public enum Distribution: String, Equatable, Sendable {
        /// App Store Connect: no device list, no debugging.
        case appStore
        /// A fixed device list, no debugging.
        case adHoc
        /// A fixed device list, debugging allowed.
        case development
        /// Every device in the team, no debugging: an enterprise profile.
        case enterprise
    }

    public var distribution: Distribution {
        if allowsDebugging { return .development }
        if hasProvisionedDevices { return .adHoc }
        return provisionsAllDevices ? .enterprise : .appStore
    }

    public func isExpired(asOf now: Date) -> Bool {
        guard let expirationDate else { return false }
        return expirationDate <= now
    }
}

// MARK: - Reading a .mobileprovision

extension ProvisioningProfile {

    /// Extracts the embedded plist from a CMS-wrapped `.mobileprovision`.
    ///
    /// The file is a PKCS#7 signed message whose payload is an XML property
    /// list. `security cms -D -i` unwraps it properly, and on a Mac that is
    /// what the workflow uses. This does the same job without Security.framework
    /// by finding the plist inside the container, so the parser is testable on
    /// any platform and against fixtures that carry no signature at all.
    ///
    /// Scanning for the payload is sound here because the surrounding DER is
    /// binary and the payload is a self-delimiting XML document: the last
    /// `</plist>` in the file always closes the first `<?xml` — an embedded
    /// certificate cannot contain either marker as literal text.
    public static func embeddedPlist(in data: Data) throws -> Data {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), options: .backwards)
        else {
            throw ProvisioningProfileError.notAProfile
        }
        guard start.lowerBound < end.upperBound else {
            throw ProvisioningProfileError.notAProfile
        }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    /// Reads a profile from the bytes of a `.mobileprovision` file, or from the
    /// already-unwrapped plist.
    public static func parse(_ data: Data) throws -> ProvisioningProfile {
        let payload = (try? embeddedPlist(in: data)) ?? data

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: payload, options: [], format: nil
            )
        } catch {
            throw ProvisioningProfileError.malformedPlist
        }
        guard let plist = object as? [String: Any] else {
            throw ProvisioningProfileError.malformedPlist
        }

        guard
            let name = plist["Name"] as? String,
            let uuid = plist["UUID"] as? String
        else {
            throw ProvisioningProfileError.missingField("Name/UUID")
        }

        // `TeamIdentifier` is an array with one element in every profile Apple
        // issues; the singular `com.apple.developer.team-identifier` entitlement
        // is the fallback for profiles that omit it.
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let team = (plist["TeamIdentifier"] as? [String])?.first
            ?? entitlements["com.apple.developer.team-identifier"] as? String
        guard let teamIdentifier = team else {
            throw ProvisioningProfileError.missingField("TeamIdentifier")
        }

        guard let applicationIdentifier = entitlements["application-identifier"] as? String
        else {
            throw ProvisioningProfileError.missingField("application-identifier")
        }

        return ProvisioningProfile(
            name: name,
            uuid: uuid,
            teamIdentifier: teamIdentifier,
            applicationIdentifier: applicationIdentifier,
            expirationDate: plist["ExpirationDate"] as? Date,
            applicationGroups: entitlements["com.apple.security.application-groups"] as? [String]
                ?? [],
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false,
            hasProvisionedDevices: (plist["ProvisionedDevices"] as? [String])?.isEmpty == false,
            allowsDebugging: entitlements["get-task-allow"] as? Bool ?? false
        )
    }
}

// MARK: - Validation

extension ProvisioningProfile {

    /// What a profile has to be true of before an archive is worth starting.
    public struct Expectation: Equatable, Sendable {
        /// Named for the report, so a failure can say *which* profile is wrong
        /// without printing any of it.
        public let role: String
        public let bundleIdentifier: String
        public let teamIdentifier: String
        /// The App Group this bundle must be granted, or nil when it needs none.
        public let applicationGroup: String?
        /// How much runway a profile needs. A profile that expires tomorrow
        /// passes `isExpired` and still strands the next build.
        public let minimumRemaining: TimeInterval

        public init(
            role: String,
            bundleIdentifier: String,
            teamIdentifier: String,
            applicationGroup: String?,
            minimumRemaining: TimeInterval = 7 * 24 * 60 * 60
        ) {
            self.role = role
            self.bundleIdentifier = bundleIdentifier
            self.teamIdentifier = teamIdentifier
            self.applicationGroup = applicationGroup
            self.minimumRemaining = minimumRemaining
        }
    }

    /// Every reason this profile cannot be used, as sentences safe to print.
    ///
    /// Safe is the operative word. Each message names the *role* — "Main",
    /// "Widgets", "Keyboard" — and the specific problem, and never the profile's
    /// contents, its team identifier, or any decoded secret. A CI log is
    /// readable by anyone who can read the repository.
    ///
    /// Returns every problem rather than the first, because a wrong profile is
    /// usually wrong in more than one way and re-running a twenty-minute job to
    /// discover the second one is the whole cost this check exists to avoid.
    public func problems(against expectation: Expectation, now: Date = Date()) -> [String] {
        var problems: [String] = []
        let role = expectation.role

        if let bundleIdentifier {
            if bundleIdentifier != expectation.bundleIdentifier {
                problems.append(
                    "\(role) provisioning profile is for a different bundle identifier "
                        + "than the \(role.lowercased()) target builds."
                )
            }
        } else {
            problems.append(
                "\(role) provisioning profile is a wildcard profile. A wildcard cannot "
                    + "carry the App Group entitlement this build needs."
            )
        }

        if teamIdentifier != expectation.teamIdentifier {
            problems.append(
                "\(role) provisioning profile belongs to a different team than the "
                    + "configured signing team."
            )
        }

        if let expirationDate {
            if expirationDate <= now {
                problems.append("\(role) provisioning profile is expired.")
            } else if expirationDate.timeIntervalSince(now) < expectation.minimumRemaining {
                let days = Int(expirationDate.timeIntervalSince(now) / 86_400)
                problems.append(
                    "\(role) provisioning profile expires in \(days) day(s). Renew it "
                        + "before it strands a release."
                )
            }
        } else {
            problems.append("\(role) provisioning profile has no expiration date.")
        }

        if distribution != .appStore {
            problems.append(
                "\(role) provisioning profile is a \(distribution.rawValue) profile. "
                    + "App Store Connect only accepts an App Store distribution profile."
            )
        }

        if let group = expectation.applicationGroup, !applicationGroups.contains(group) {
            problems.append(
                "\(role) provisioning profile does not grant the App Group this build "
                    + "shares between the app and its extensions."
            )
        }

        return problems
    }

    /// A one-line description safe to write to a build log.
    ///
    /// Name, expiry and kind. Not the team identifier, not the application
    /// identifier, not the groups — the name is what a human needs in order to
    /// recognise the profile, and everything else has already been checked by
    /// something that does not need to print it.
    public var logSummary: String {
        let expiry = expirationDate.map(Self.logDateFormatter.string(from:)) ?? "no expiry"
        return "\(name) — \(distribution.rawValue), expires \(expiry)"
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public enum ProvisioningProfileError: Error, Equatable, CustomStringConvertible {
    case notAProfile
    case malformedPlist
    case missingField(String)

    public var description: String {
        switch self {
        case .notAProfile:
            return "The file does not contain a provisioning profile payload."
        case .malformedPlist:
            return "The provisioning profile payload is not a readable property list."
        case .missingField(let field):
            return "The provisioning profile is missing \(field)."
        }
    }
}
