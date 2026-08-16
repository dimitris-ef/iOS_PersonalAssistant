import SwiftUI

/// Shown when the data store could not be opened.
///
/// This screen exists so the app has an honest failure mode. The tempting
/// alternative — fall back to in-memory storage and carry on — produces an app
/// that behaves perfectly for a whole session and then loses everything, with
/// the user having had no reason to suspect anything was wrong. Refusing to
/// start is worse for one launch and better for their data.
///
/// It offers no "reset" or "start fresh" button on purpose. Deleting the
/// database is the one action that turns a recoverable problem — a failed
/// migration, a full disk, a file locked by a stuck process — into permanent
/// loss, and it is not a choice to put behind a button on a screen someone
/// meets when they are already frustrated.
struct PersistenceFailureView: View {
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Your data couldn't be opened")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("The assistant won't start rather than run without your conversations, tasks and memories — carrying on would risk losing anything you added in the meantime.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("What to try")
                    .font(.footnote.weight(.semibold))
                Text("Close the app fully and reopen it. If it keeps happening, check that the device has free storage. Your data has not been deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )

            #if DEBUG
            // The underlying error is a developer detail. It can name a file
            // path and a migration stage, so it stays out of release builds
            // rather than being shown to someone who cannot act on it.
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            #endif

            Spacer()
        }
        .padding(Theme.Spacing.lg)
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    PersistenceFailureView(detail: "PersistenceError.initializationFailed(...)")
}
