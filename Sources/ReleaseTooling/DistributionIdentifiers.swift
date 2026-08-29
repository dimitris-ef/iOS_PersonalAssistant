import Foundation

/// The identifiers this app is distributed under, and the check that they are
/// real ones.
///
/// ## Why a second copy of strings that already exist
///
/// `SystemSurfaceIdentifiers` is the *runtime* source of truth — it is what the
/// app, the widgets and the keyboard read. This is the *distribution* source of
/// truth: what the deploy workflow signs, exports and uploads, and what App
/// Store Connect has a record for.
///
/// They must be equal, and a test asserts they are. Writing them twice and
/// asserting equality is not duplication for its own sake: it is the only way
/// to notice that someone changed the app's bundle identifier without changing
/// what gets uploaded, which would otherwise archive cleanly and be rejected —
/// or worse, uploaded to the wrong App Store Connect record.
///
/// `ReleaseTooling` deliberately does not depend on `SystemSurfaces`. If it did,
/// the two constants would be the same constant and the test would be checking
/// that a string equals itself.
public enum DistributionIdentifiers {
    public static let appBundleID = "com.dimitrisefthymiou.MetisAI"
    public static let widgetsBundleID = "com.dimitrisefthymiou.MetisAI.widgets"
    public static let keyboardBundleID = "com.dimitrisefthymiou.MetisAI.keyboard"
    public static let appGroup = "group.com.dimitrisefthymiou.MetisAI"

    /// Every bundle identifier the archive is expected to contain.
    public static let allBundleIDs = [appBundleID, widgetsBundleID, keyboardBundleID]
}

/// Catches an identifier that was never filled in.
///
/// ## The failure this prevents
///
/// A placeholder bundle identifier does not fail to build. It fails at the end:
/// the archive is signed against a profile for the real identifier and the
/// mismatch surfaces as an export error, or — worse — the identifier is
/// genuinely registered to somebody else's sample project and the upload is
/// rejected on ownership grounds after twenty minutes of processing.
///
/// So it is checked before the archive rather than after, and checked against a
/// list of the things people actually leave behind rather than against one
/// known-bad string.
public enum IdentifierPlaceholderCheck {

    /// Fragments that mean "this was never configured".
    ///
    /// Matched case-insensitively on identifier components, not as substrings of
    /// the whole string: `com.mycompany.Example` must fail, and a real company
    /// whose name happens to contain one of these words must not.
    static let placeholderComponents: Set<String> = [
        "example", "test", "sample", "demo", "changeme", "placeholder",
        "yourcompany", "mycompany", "company", "acme", "todo", "untitled",
        "myapp", "yourapp", "app1", "foo", "bar",
    ]

    /// Reverse-DNS prefixes that are reserved or reserved-in-practice.
    static let reservedPrefixes = ["com.example.", "org.example.", "com.apple.", "com.yourcompany."]

    /// Returns a sentence per problem, empty when the identifier is usable.
    public static func problems(in identifier: String, role: String) -> [String] {
        var problems: [String] = []

        if identifier.isEmpty {
            return ["\(role) bundle identifier is empty."]
        }

        let lowered = identifier.lowercased()

        for prefix in reservedPrefixes where lowered.hasPrefix(prefix) {
            problems.append(
                "\(role) bundle identifier still uses the reserved prefix '\(prefix)'. "
                    + "It has not been changed to a production identifier."
            )
        }

        let components = lowered.split(separator: ".").map(String.init)
        for component in components where placeholderComponents.contains(component) {
            problems.append(
                "\(role) bundle identifier contains the placeholder component "
                    + "'\(component)'."
            )
        }

        if components.count < 3 {
            problems.append(
                "\(role) bundle identifier '\(identifier)' is not reverse-DNS with at "
                    + "least three components."
            )
        }

        // Apple accepts alphanumerics, hyphen and period. Anything else — an
        // underscore, a space, a stray quote from a shell variable that did not
        // expand — is refused at upload, long after it could have been noticed.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        if identifier.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            problems.append(
                "\(role) bundle identifier contains characters Apple does not allow. "
                    + "Only letters, digits, hyphen and period are permitted."
            )
        }

        return problems
    }

    /// Checks the whole shipping set, including that the extensions really are
    /// children of the app.
    ///
    /// The child relationship is not cosmetic: iOS requires an app extension's
    /// bundle identifier to be prefixed by its containing app's, and an
    /// extension that breaks the rule is rejected at validation with a message
    /// about `CFBundleIdentifier` that names neither target.
    public static func problemsInShippingSet() -> [String] {
        var problems = problems(in: DistributionIdentifiers.appBundleID, role: "Main")
            + problems(in: DistributionIdentifiers.widgetsBundleID, role: "Widgets")
            + problems(in: DistributionIdentifiers.keyboardBundleID, role: "Keyboard")

        for (role, identifier) in [
            ("Widgets", DistributionIdentifiers.widgetsBundleID),
            ("Keyboard", DistributionIdentifiers.keyboardBundleID),
        ] where !identifier.hasPrefix(DistributionIdentifiers.appBundleID + ".") {
            problems.append(
                "\(role) bundle identifier is not a child of the app's bundle identifier."
            )
        }

        if DistributionIdentifiers.appGroup != "group." + DistributionIdentifiers.appBundleID {
            problems.append(
                "The App Group is not derived from the app's bundle identifier."
            )
        }

        return problems
    }
}
