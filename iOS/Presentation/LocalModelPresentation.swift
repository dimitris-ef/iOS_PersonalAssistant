import AIProviderLocal
import AssistantDomain
import Foundation
import NativeModelKit

/// How local models are described on screen.
///
/// ## The rule this file exists to enforce
///
/// Section 70: do not overload users with llama.cpp terminology. Nowhere in the
/// UI does the word *GGUF*, *quantization*, *KV cache*, *context window*,
/// *tensor* or *Metal* appear as something a normal user has to understand.
/// "Q4_K_M" survives as a small caption because it is the string people compare
/// downloads by on every model page they have ever seen — but it is never
/// explained, never required, and never the primary label.
///
/// Sizes are rounded. A byte count implies a precision that neither the catalog
/// nor the memory estimate has.
enum LocalModelPresentation {
    /// "2.0 GB", "484 MB".
    static func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let gigabytes = Double(bytes) / Double(Int64.gigabyte)
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return "\(max(1, bytes / .megabyte)) MB"
    }

    /// "1.4 GB of 2.3 GB" — what a progress bar cannot say on its own.
    static func transferred(_ progress: LocalModelDownloadProgress) -> String {
        guard let total = progress.bytesExpected, total > 0 else {
            return size(progress.bytesReceived)
        }
        return "\(size(progress.bytesReceived)) of \(size(total))"
    }

    /// "1.7B · Q4_K_M" — the two things people actually compare.
    static func specification(_ descriptor: LocalModelDescriptor) -> String {
        [descriptor.parameterLabel, descriptor.quantization?.rawValue]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The status line under a model's name.
    static func statusLabel(_ status: LocalModelStatus) -> String {
        if status.lifecycle.isInstalled, status.isSelected {
            return status.lifecycle.isLoaded ? "Ready" : "Selected"
        }
        return status.lifecycle.label
    }

    /// What the compatibility badge says.
    ///
    /// Fit, never speed. Section 121: nothing here may claim a tokens-per-second
    /// figure, because nothing here has measured one — that is a real-device
    /// question and stays one.
    static func compatibilityLabel(_ status: LocalModelStatus) -> String {
        status.compatibility.shortLabel
    }

    /// The longer explanation, when there is one worth reading.
    static func compatibilityDetail(_ status: LocalModelStatus) -> String? {
        status.compatibility.reason
    }

    /// Whether the badge should read as a warning.
    static func isWarning(_ compatibility: LocalModelCompatibility) -> Bool {
        !compatibility.permitsDownload
    }

    /// What the model can do for the assistant.
    ///
    /// Section 130: useful status, no parser internals.
    static func capabilityLabel(_ descriptor: LocalModelDescriptor) -> String {
        descriptor.toolSupport.label
    }

    /// How the file was verified, said plainly.
    ///
    /// The distinction matters and is not hidden: a published checksum proves
    /// the bytes are the bytes that were published, and a structural check only
    /// proves the file is a model of the right kind. Claiming the stronger one
    /// where only the weaker ran would be the kind of security theatre this
    /// codebase is meant not to do.
    static func verificationLabel(_ record: LocalModelRecord) -> String {
        record.checksumWasDeclared
            ? "Verified against the published checksum"
            : "Checked for a valid model file (no published checksum to compare)"
    }

    /// The privacy summary shown under Local AI (section 129).
    ///
    /// Careful about what it claims. "Works offline after the model is
    /// downloaded" is true of *conversation*; it is not true of an action that
    /// needs the network, and the last line says so rather than letting someone
    /// conclude the whole app works in a tunnel.
    static let privacySummary = """
        Runs on this device. No API key. Your messages, memories and \
        conversations are never sent anywhere for a reply.

        Downloading a model needs the internet once. After that, replies work \
        offline — though actions that reach other services, like a shared \
        calendar, still need a connection of their own.
        """

    /// The battery note. Honest, unquantified (section 120).
    static let batteryNote =
        "Local models do a lot of work on the device, so long conversations can "
        + "use noticeably more battery and make the phone warm."

    /// The sentence the delete confirmation says.
    ///
    /// Spelled out rather than assumed, because "delete" next to something the
    /// assistant runs on reasonably makes people wonder what else goes with it.
    static func deletionExplanation(_ status: LocalModelStatus) -> String {
        "Deletes \(status.descriptor.displayName) and frees "
            + "\(size(status.installed?.fileSizeBytes ?? status.descriptor.fileSizeBytes)). "
            + "Your conversations, memories, tasks and settings are not affected."
    }
}
