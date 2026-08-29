# Deployment

How MetisAI gets from this repository onto a real iPhone through TestFlight.

Everything here is Part 14. Parts 1–13 built an app that compiles and passes
tests; this is the part that makes it installable by a person who is not the
author.

## The identifiers

Four strings, registered with Apple, and treated as fixed data rather than
configuration. Changing any of them orphans the shared container of every
installed copy.

| Role | Identifier |
| --- | --- |
| Main application | `com.dimitrisefthymiou.MetisAI` |
| Widget extension | `com.dimitrisefthymiou.MetisAI.widgets` |
| Keyboard extension | `com.dimitrisefthymiou.MetisAI.keyboard` |
| App Group | `group.com.dimitrisefthymiou.MetisAI` |

They are declared **once**, in
`Sources/SystemSurfaces/SystemSurfaceIdentifiers.swift`. That file is in the
only package target the keyboard extension links — `SystemSurfaces` imports
nothing but Foundation — so the app, the widgets and the keyboard can all read
the App Group identifier without any of them dragging in SwiftData, the engine
or an inference runtime. The BGTaskScheduler identifier and the Keychain
service are derived from the same prefix for the same reason: they cannot drift.

Three things still repeat the strings, because a plist cannot import Swift:

* `project.yml` — `PRODUCT_BUNDLE_IDENTIFIER` for each of the three targets
* the three `.entitlements` files — the App Group
* `iOS/Resources/Info.plist` — the BGTask identifier and the URL scheme

`Tests/SystemSurfacesTests` and `Tests/ReleaseToolingTests` assert the Swift
halves agree, and the deploy workflow checks the built bundles against the
expected values before it uploads anything.

### The URL scheme

`metisai`, not `personalassistant`. URL schemes are claimed
first-come-first-served across the whole device, so a generic one is a
collision waiting to happen: another app registering `personalassistant` would
start receiving this app's widget taps, with no error on either side.

## Entitlements

One, on all three targets: `com.apple.security.application-groups`.

That is the complete list, and it is deliberate. No Push Notifications, no
iCloud, no Associated Domains, no HealthKit, no Sign in with Apple. Each of
those would have to be enabled on the App ID, granted in each provisioning
profile, and justified at review — for a capability nothing in the code uses.

Background modes are an Info.plist key rather than an entitlement, and the app
declares exactly one: `fetch`. What it buys is an *earlier* correction when a
reminder has been ignored. Reminders themselves are delivered by
`UNUserNotificationCenter` and AlarmKit whether or not this process exists,
which is the whole architecture and the reason nothing about correctness
depends on a background refresh ever running.

`NSSupportsLiveActivities` was added in this milestone. ActivityKit requires it
in the **main app's** Info.plist, not the widget extension's, and without it
`Activity.request` throws `unsupported` on every device — no build error, no
log line, the Live Activity simply never appears. It is the class of failure
that only shows up on real hardware, which is what this milestone is for.

## Signing

Debug is unsigned. That is what keeps the two simulator CI lanes runnable on a
stock runner with an empty keychain, and it is unchanged from Part 12.

Release is manually signed against three per-target App Store distribution
profiles. The profile *names* arrive as build variables:

```
METIS_TEAM_ID
METIS_MAIN_PROFILE_NAME
METIS_WIDGETS_PROFILE_NAME
METIS_KEYBOARD_PROFILE_NAME
```

Names rather than UUIDs, and none of them hardcoded: the workflow decodes each
profile, reads the name Apple actually put in it, and passes it on the
`xcodebuild` command line. A profile regenerated in the developer portal keeps
its name and changes its UUID, so a pinned UUID would break the build the first
time anyone renewed a certificate.

Each extension gets its **own** profile. This is not bureaucracy: the App Group
entitlement is granted to a bundle identifier, and an extension signed with the
app's profile installs happily and then cannot see the shared container.

There is no `-allowProvisioningUpdates` anywhere. Its absence is the point — a
build that silently regenerates its own profiles is a build whose entitlements
nobody reviewed.

## Repository secrets

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | The Apple Developer team identifier |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | base64 of the `.p12` |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | the `.p12` password |
| `IOS_MAIN_PROFILE_BASE64` | base64 of the app's `.mobileprovision` |
| `IOS_WIDGETS_PROFILE_BASE64` | base64 of the widgets' `.mobileprovision` |
| `IOS_KEYBOARD_PROFILE_BASE64` | base64 of the keyboard's `.mobileprovision` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | base64 of the whole `.p8`, BEGIN/END lines included |
| `APP_STORE_CONNECT_KEY_ID` | the key identifier |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer identifier |

None of them has a plaintext copy in this repository, and none of them is ever
printed. The rules the workflow follows:

* Decoded material is redirected straight into a file created under
  `umask 077` and `chmod 600` — never onto stdout, never into a variable.
* No `set -x` in any step that touches a secret.
* Verification without disclosure: the signing identity is *counted* and
  *matched*, never echoed, because `security find-identity` prints a common
  name carrying the developer's name and team.
* Every failure message names the role — "Main", "Widgets", "Keyboard" — and
  the problem, and nothing from inside the file. A CI log is readable by anyone
  who can read the repository, and GitHub's secret masking does not cover
  *decoded* variants of a secret, so nothing decoded is printed at all.
* Artifacts are logs only. Never the IPA, the archive, a profile or a key.

The App Store Connect key is CI distribution infrastructure and must never
enter the app bundle. That is enforced structurally — `ReleaseTooling` and
`TestFlightTool` are absent from `project.yml`, so no app target can import
them — and checked again on the exported IPA, which is scanned for `AuthKey_*`,
`.p8`, `.p12`, stray `.mobileprovision` files and for any PEM private key
header anywhere in the payload.

## The deploy workflow

`.github/workflows/testflight-deploy.yml`. Triggered by hand
(`workflow_dispatch`) or by a `testflight-*` tag. **Never** on a pull request,
and never `pull_request_target`: a fork's pull request must not be able to
reach the signing identity.

`concurrency` is `cancel-in-progress: false`. An upload cancelled halfway
leaves a build number consumed and a partial transfer Apple may or may not have
registered — the worst state this workflow can be interrupted into.

What it does, in order:

1. Confirm every required secret is set — presence only, before anything else
   spends time.
2. Build `testflight-tool` from the package.
3. Refuse to ship a placeholder identifier.
4. Resolve the build number.
5. Import the distribution certificate into a **temporary** keychain created
   for this job. The runner's `login.keychain` is never touched.
6. Decode, validate and install the three provisioning profiles.
7. Install the App Store Connect key at
   `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, where `altool` looks
   for it by convention.
8. Confirm an App Store Connect app record exists for
   `com.dimitrisefthymiou.MetisAI`. Nothing in CI can create one, so
   discovering it is missing after a forty-minute build helps nobody.
9. `xcodegen generate`, then `swift test`.
10. `xcodebuild archive` for `generic/platform=iOS`, Release.
11. Verify the archive.
12. Generate ExportOptions.plist and export the IPA.
13. Verify the IPA, and scan it for build credentials.
14. `altool --validate-app`, then `altool --upload-app`.
15. Poll the Builds API until this exact build settles.
16. `if: always()` — delete the keychain, the profiles, the key and the whole
    run directory.

### The build number

`GITHUB_RUN_NUMBER`.`GITHUB_RUN_ATTEMPT`, applied as `CURRENT_PROJECT_VERSION`
on the `xcodebuild` command line, which applies it to all three targets at once
— three separately edited values would not stay in step.

`CFBundleVersion` is the primary key of a build within a marketing version.
Upload a number App Store Connect has already seen and the upload is rejected
after the archive, after the export, after the transfer; there is no way to
replace a build, only to supersede it. The run number never repeats, and the
attempt separates a re-run from the run it re-runs — so a deploy that failed
*after* uploading cannot collide with itself when re-run.

`MARKETING_VERSION` is preserved, not generated. It is `0.1` in `project.yml`,
and a test checks it is a shape `CFBundleShortVersionString` accepts.

There is a `build_number_override` input for exactly one situation: a run whose
upload succeeded and whose *polling* failed, which must be re-checked against
the number already in App Store Connect. It is validated rather than trusted,
because an override goes into a signed binary and onto a command line.

### What is verified, and why each check exists

Every one of these is something that produces a confusing failure much later.

**On the archive**

| Check | The failure it prevents |
| --- | --- |
| all three bundles present | a missing extension is an App Store rejection |
| bundle identifiers | signed against the wrong record |
| build number identical across all three | a TestFlight build that never appears |
| marketing version identical across all three | a validation error naming no target |
| `embedded.mobileprovision` present | a bundle that will not install, with no warning |
| `codesign --verify` | a signature problem found at upload |
| team identifier | certificate and profile from different teams |
| **signed** entitlements contain the App Group | widgets showing a placeholder forever on a real device |
| dSYMs present | every tester's crash report is a column of hex |

The entitlements are read from the binary with `codesign -d --entitlements`,
not from the `.entitlements` file in the repository. Those are the input; what
matters is what codesign actually applied.

**On the IPA** — the same identifier, build-number and App Group checks, run
again. The export re-signs every bundle, so the archive being right does not
make the IPA right.

### Why the workflow does not end at "uploaded"

`altool --upload-app` exits zero when Apple has accepted the **transfer**.
Whether the binary is usable is decided minutes later, and a build that fails
processing is invisible in TestFlight with no signal at the upload site.

So the last step queries `GET /v1/builds` for this exact `CFBundleVersion` and
fails unless `processingState` is `VALID`. `FAILED` and `INVALID` fail
immediately rather than waiting out the timeout. A state the tool does not
recognise is treated as terminal and *not* as success — guessing there would
mean reporting a build as shipped on the strength of a string nobody has seen.

The filter is on the build number, never "the most recent build". Two deploys
racing, or a build uploaded by hand from a laptop, and the newest build is not
the one this run produced; reporting its success as this run's success is the
exact false green this step exists to prevent.

## The release tooling

`Sources/ReleaseTooling` — no dependencies, and that is the design. It cannot
import `SystemSurfaces`, so its copy of the shipping identifiers is a genuinely
separate statement of them that a test compares against the runtime one. If
they were the same constant, that test would be checking a string against
itself.

| File | What it decides |
| --- | --- |
| `ProvisioningProfile.swift` | what a `.mobileprovision` says, and every reason it cannot be used |
| `DistributionIdentifiers.swift` | the shipping identifiers, and the placeholder check |
| `BuildNumber.swift` | the build number, and override validation |
| `ExportOptions.swift` | the plist that drives `-exportArchive` |
| `AppStoreConnectToken.swift` | the ES256 bearer token |
| `BuildProcessing.swift` | the Builds API, and the polling loop |

`Sources/TestFlightTool` is the command line the workflow drives. Credentials
are read from `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` in the
environment, never from arguments — process arguments are visible to every
other process via `ps` and end up in xtrace output.

This is Swift rather than shell because a repository whose only compiler is CI
cannot check a shell pipeline before running it. A mistake in profile parsing
or in the build-number format would otherwise be found by a forty-minute job
failing, or — worse — by a job succeeding on the wrong build.

## Export compliance

`ITSAppUsesNonExemptEncryption` is declared `false`, after auditing what the
binary actually does:

* HTTPS to OpenAI through `URLSession` — Apple-provided TLS, exempt.
* Credentials in the Keychain through Security.framework — exempt.
* SHA-256 over downloaded model files — a hash, used for integrity.

There is no bundled cipher, no custom TLS stack and no encrypted format of our
own. If that stops being true, the key must be removed and the question
answered honestly in App Store Connect.

## What the first real deploy established

Run [33223698046](https://github.com/dimitris-ef/iOS_PersonalAssistant/actions/runs/33223698046),
on `efcdc39`, build **2.1**. All 22 steps succeeded on the first attempt.

```
The app:      com.dimitrisefthymiou.MetisAI          0.1 (2.1), signed, App Group present.
The widgets:  com.dimitrisefthymiou.MetisAI.widgets  0.1 (2.1), signed, App Group present.
The keyboard: com.dimitrisefthymiou.MetisAI.keyboard 0.1 (2.1), signed, App Group present.
Archive carries 3 dSYM bundle(s).
Exported PersonalAssistant.ipa (9.0M)
--- scanning the payload for build credentials ---
No build credentials found in the payload.
UPLOAD SUCCEEDED with no errors
Transfer accepted for build 2.1. This is not yet a usable build.
Waiting for build 2.1 of com.dimitrisefthymiou.MetisAI to finish processing.
  build 2.1 has not appeared in App Store Connect yet.
  build 2.1 has not appeared in App Store Connect yet.
  build 2.1 has not appeared in App Store Connect yet.
  build 2.1: VALID
Build 2.1 is VALID and available in TestFlight.
```

The three "has not appeared" lines matter: the poll did not pass vacuously on
a build that was already there. It asked for build `2.1` specifically, found
nothing four times over ninety seconds, and settled only when that exact
`CFBundleVersion` reported `VALID`.

## Running a deploy

Actions → **TestFlight Deploy** → Run workflow, on
`claude/iphone-ai-assistant-arch-ww96mv`. Or push a tag:

```
git tag testflight-2026-08-29
git push origin testflight-2026-08-29
```

Optional inputs: `build_number_override` (see above) and
`poll_deadline_minutes`, which defaults to 45.

## Device-only validation remaining

None of this can be checked from CI, and none of it is claimed to have been.
A green deploy proves the build is signed correctly, exports, uploads and
finishes processing — it proves nothing about how the app behaves once
installed.

Still to confirm on a real iPhone, from TestFlight:

* **The app launches.** A crash on first launch is the one failure a signed,
  processed, VALID build can still have.
* **The App Group container resolves.** The profiles grant the entitlement and
  the signed binaries carry it, but no runner has ever called
  `containerURL(forSecurityApplicationGroupIdentifier:)` on this bundle.
* **Widgets show real data**, not the placeholder that appears when the shared
  container is nil.
* **The keyboard appears** in Settings › General › Keyboards, and typing works
  with Full Access **off** — the Part 12 requirement that is invisible to CI.
* **Live Activities start.** `NSSupportsLiveActivities` is now declared; that
  it works has never been observed.
* **Deep links open.** `metisai://open/task?id=…` from a widget tap.
* **The background refresh registers.** A BGTask identifier that disagrees with
  the Info.plist traps at launch; the two now derive from one constant, but the
  registration has never run.
* **Permission prompts read correctly** — calendar, reminders, microphone,
  speech recognition, notifications, and AlarmKit on iOS 26.
* **The SwiftData store migrates** from a previous install, including the
  move into the group container.
* **Speech providers work on device.** Apple Speech, and whisper.cpp with a
  downloaded model — the local runtime has never run on an ARM device (see
  `Docs/SPEECH.md`).
* **Local LLM inference.** llama.cpp has no simulator slice at all, so it has
  never executed anywhere.
* **Memory and thermals** under a real model load on a real phone.
* **The app icon on the Home Screen.** `AppIcon.appiconset` holds a single
  1024×1024 PNG with no alpha channel, which is the current single-size format
  and the one App Store Connect requires; that it renders well at 60pt on a
  device has not been looked at.
