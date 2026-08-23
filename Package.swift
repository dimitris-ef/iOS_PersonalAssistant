// swift-tools-version:5.9
//
// PhonePersonalAI — a native iPhone personal AI assistant.
//
// This package contains ONLY the platform-independent parts of the product:
// the domain models, the assistant "brain", the AI provider abstraction, the
// tool system, the platform protocols and their mock implementations.
//
// It is deliberately buildable on Linux/Windows (no SwiftUI, no Apple-only
// frameworks) so the core can be developed and tested before a Mac is
// available. The SwiftUI application and the Apple framework adapters live in
// `iOS/` and are added to an Xcode project later — see `iOS/README.md`.

import PackageDescription
import Foundation

// MARK: The llama.cpp runtime
//
// Local inference is powered by llama.cpp, pinned to a specific upstream build
// and consumed as the XCFramework that build publishes. Two facts about that
// artifact shape everything below, and neither is a preference:
//
//  1. **It has no iOS Simulator slice.** `llama-b10506-xcframework.zip` ships
//     `ios-arm64` and `macos-arm64_x86_64` and nothing else. An app target that
//     links it cannot be built for the simulator at all — the linker fails
//     outright — which would take the simulator CI lane and every SwiftUI
//     preview down with it.
//  2. **It is Apple-only, and 80 MB.** Adding it unconditionally would make
//     `swift build` on Linux or Windows fail to resolve, and would make every
//     CI run download it whether or not that run touches inference.
//
// So the binary dependency is opt-in, through an environment variable read at
// manifest evaluation. `AIProviderLocalLlama` is *always* a target and always
// compiles; what changes is whether it has the `llama` module to import, which
// it detects with `#if canImport(llama)`. With the flag off it builds to a
// runtime that reports itself unavailable — the same graceful path a device
// with no downloaded model already takes.
//
//     PPAI_LLAMA_RUNTIME=1 swift build          # links llama.cpp
//     PPAI_LLAMA_RUNTIME=1 xcodegen generate    # device builds get it too
//     swift build                               # everything else, no download
//
// The `Local model runtime` CI workflow builds with the flag on, so the
// integration is compiled and linked on every change rather than only when
// somebody remembers.
//
// Pinning: an upstream build tag, never a branch. Section 83 — `master` moves
// several times a day, and a dependency that changes underneath CI is a
// dependency that fails for reasons nobody in this repository can reproduce.
let llamaVersion = "b10506"
let llamaChecksum = "4a8ce464f3743d5035906ed1f5d7e3474b086ee1e082779be2268510cdcddf7c"
let llamaRuntimeEnabled = ProcessInfo.processInfo.environment["PPAI_LLAMA_RUNTIME"] == "1"

let llamaBinaryTargets: [Target] = llamaRuntimeEnabled
    ? [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/"
                + "\(llamaVersion)/llama-\(llamaVersion)-xcframework.zip",
            checksum: llamaChecksum
        ),
    ]
    : []

let llamaRuntimeDependencies: [Target.Dependency] = llamaRuntimeEnabled
    ? ["AIProviderLocal", "llama"]
    : ["AIProviderLocal"]

let package = Package(
    name: "PhonePersonalAI",
    // These minimums matter only when the package is consumed from Xcode.
    //
    // Still iOS 17, and staying there. Foundation Models and AlarmKit both
    // need iOS 26, and both are adopted — behind `#if canImport` for the SDK
    // and `if #available` for the device, with the frameworks weakly linked so
    // dyld will still start the app on an OS that lacks them. Raising the
    // minimum to 26 would trade most of the addressable devices for two
    // optional features those devices could never have run, when almost
    // everything the app does — tasks, reminders, the follow-up ladder,
    // memory, the calendar — has nothing to do with either.
    //
    // macOS 14 is the floor for SwiftData, which `AssistantPersistenceSwiftData`
    // needs; iOS 17 already was. Nothing else in the package requires it, and
    // the iOS deployment target is unchanged. Raised only because the store
    // could not otherwise be opened on a Mac — including in the tests that
    // verify it.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AssistantDomain", targets: ["AssistantDomain"]),
        .library(name: "AssistantAI", targets: ["AssistantAI"]),
        .library(name: "AssistantTools", targets: ["AssistantTools"]),
        .library(name: "AssistantPlatform", targets: ["AssistantPlatform"]),
        .library(name: "AssistantPersistence", targets: ["AssistantPersistence"]),
        // The production store. Apple-only in practice — every file is behind
        // `#if canImport(SwiftData)`, so the target still builds on Linux and
        // Windows, it just contains nothing there.
        .library(name: "AssistantPersistenceSwiftData", targets: ["AssistantPersistenceSwiftData"]),
        .library(name: "ExecutiveSupport", targets: ["ExecutiveSupport"]),
        .library(name: "PersonalMemory", targets: ["PersonalMemory"]),
        // Apple's on-device sentence embeddings, alone in their own target so
        // the memory architecture stays buildable where NaturalLanguage is not.
        .library(name: "PersonalMemoryApple", targets: ["PersonalMemoryApple"]),
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        // What the keyboard and the widgets are allowed to see.
        //
        // Foundation and nothing else, so an extension that links it does not
        // drag in the domain, the repositories, a provider or a runtime. That
        // is the point: a widget extension with `AIProviderLocalLlama` in its
        // graph is an 80 MB widget extension.
        .library(name: "SystemSurfaces", targets: ["SystemSurfaces"]),
        .library(name: "MockPlatform", targets: ["MockPlatform"]),
        // The real iPhone: EventKit, UserNotifications, AlarmKit. Apple-only
        // in practice — every framework import is behind `#if canImport`, so
        // the target still builds on Linux and Windows, where it contains only
        // the mapping layer.
        .library(name: "AssistantPlatformApple", targets: ["AssistantPlatformApple"]),
        // Speech in, speech out. The state machine is framework-free and builds
        // everywhere; the Apple implementations are iOS-only and behind guards.
        .library(name: "AssistantVoice", targets: ["AssistantVoice"]),
        .library(name: "AIProviderRemote", targets: ["AIProviderRemote"]),
        .library(name: "AIProviderApple", targets: ["AIProviderApple"]),
        .library(name: "AIProviderLocal", targets: ["AIProviderLocal"]),
        // The llama.cpp adapter, alone in its own target so the model system
        // above it stays buildable — and testable — where llama.cpp is not.
        .library(name: "AIProviderLocalLlama", targets: ["AIProviderLocalLlama"]),
        // Development-only. Exposed as a product so the iOS app target can use
        // the scripted stand-in while no real provider is implemented; drop it
        // from the app's dependencies once one is.
        .library(name: "DevSupport", targets: ["DevSupport"]),
        .executable(name: "assistant-dev", targets: ["DevHarness"]),
    ],
    targets: llamaBinaryTargets + [
        // MARK: Core

        .target(name: "AssistantDomain"),

        .target(name: "AssistantAI", dependencies: ["AssistantDomain"]),

        .target(name: "AssistantTools", dependencies: ["AssistantDomain"]),

        .target(name: "AssistantPlatform", dependencies: ["AssistantDomain"]),

        // Depends on AssistantTools for `AssistantActionPlan`: what the
        // assistant did is part of a stored conversation, not a separate
        // concept. The dependency is one-way — the tool layer knows nothing
        // about storage.
        .target(
            name: "AssistantPersistence",
            dependencies: ["AssistantDomain", "AssistantTools", "PersonalMemory"]
        ),

        // SwiftData lives here and nowhere else. No core target depends on it,
        // which is what keeps the package buildable where SwiftData is not.
        .target(
            name: "AssistantPersistenceSwiftData",
            dependencies: [
                "AssistantDomain",
                "AssistantPersistence",
                "AssistantTools",
                "PersonalMemory",
            ]
        ),

        .target(name: "ExecutiveSupport", dependencies: ["AssistantDomain"]),

        // Memory relevance: ranking, deduplication and prompt formatting.
        // Pure and domain-only, like ExecutiveSupport — no repositories, no
        // providers, no network. That is what lets retrieval be exhaustively
        // tested and lets it run offline before every turn.
        .target(name: "PersonalMemory", dependencies: ["AssistantDomain"]),

        // The only place `NaturalLanguage` is imported.
        //
        // Nothing in the core depends on this target; the app composes it in at
        // launch and everything below sees only `SemanticEncoder`. That is what
        // keeps ranking, consolidation, aging and every memory test running on
        // Linux, on Windows and in CI, where the framework does not exist — and
        // what makes swapping in a Core ML model later a new conformance rather
        // than a change to the memory system.
        .target(name: "PersonalMemoryApple", dependencies: ["PersonalMemory"]),

        // The extension-safe projection layer.
        //
        // Depends on nothing — deliberately, and the dependency list is the
        // architectural claim: a keyboard extension cannot reach a repository,
        // a provider or the engine, because none of them is in its graph. What
        // crosses into an extension is the handful of small `Codable` values
        // defined in this target and nothing else.
        .target(name: "SystemSurfaces"),

        .target(
            name: "AssistantCore",
            dependencies: [
                "AssistantDomain",
                "AssistantAI",
                "AssistantTools",
                "AssistantPlatform",
                "AssistantPersistence",
                "ExecutiveSupport",
                "PersonalMemory",
                // One-way: the core builds projections for the surfaces; the
                // surfaces know nothing about the core.
                "SystemSurfaces",
            ]
        ),

        // MARK: Platform implementations

        .target(name: "MockPlatform", dependencies: ["AssistantDomain", "AssistantPlatform"]),

        // The Apple adapters. This lives in the package rather than in `iOS/`
        // on purpose: `iOS/` has no test target, and the parts most worth
        // testing here — which notification action means "done", which means
        // "dismissed", how an identifier round-trips — are pure functions that
        // need no simulator. Putting them in a package target is what makes
        // them compiled and executed by CI instead of only read.
        //
        // It depends on ExecutiveSupport for `ReminderOutcome`: translating a
        // notification response into a support outcome is this layer's job,
        // and the alternative was to leave that translation in the untested
        // app target.
        .target(
            name: "AssistantPlatformApple",
            dependencies: ["AssistantDomain", "AssistantPlatform", "ExecutiveSupport"]
        ),

        // Voice input and output.
        //
        // Depends on *nothing* in this package, which is the architectural
        // claim of the milestone expressed as a dependency list: the voice
        // layer cannot reach the engine, a provider, a repository or a
        // platform service, because none of them is available to it. It turns
        // speech into a `String` and hands it to a closure.
        .target(name: "AssistantVoice"),

        // MARK: AI providers

        .target(name: "AIProviderRemote", dependencies: ["AssistantDomain", "AssistantAI"]),
        .target(name: "AIProviderApple", dependencies: ["AssistantDomain", "AssistantAI"]),
        // The local-model system: catalog, compatibility, downloads,
        // verification, storage, the runtime abstraction and the provider.
        // Everything except inference, and therefore everything that can be
        // tested without a GPU or a two-gigabyte file.
        //
        // Depends on `AssistantPersistence` for the installed-model rows. That
        // is one-way: persistence knows nothing about providers, and the record
        // it stores lives in `AssistantDomain`.
        .target(
            name: "AIProviderLocal",
            dependencies: ["AssistantDomain", "AssistantAI", "AssistantPersistence"],
            resources: [.process("Resources")]
        ),

        // The only place `llama` is imported.
        //
        // Always compiled, so the adapter cannot silently rot; linked against
        // the real runtime only when `PPAI_LLAMA_RUNTIME=1` puts the binary
        // target in the graph. See the note at the top of this file for why
        // that is opt-in rather than always on.
        .target(name: "AIProviderLocalLlama", dependencies: llamaRuntimeDependencies),

        // MARK: Development-only

        .target(
            name: "DevSupport",
            // `AssistantCore` is here for `ConsoleAgentLogger` alone, which
            // implements the engine's `AgentLogger`. The dependency runs this
            // way round on purpose: the core knows nothing about a console.
            dependencies: ["AssistantDomain", "AssistantAI", "AssistantTools", "AssistantCore"]
        ),

        .executableTarget(
            name: "DevHarness",
            dependencies: [
                "AssistantDomain",
                "AssistantAI",
                "AssistantTools",
                "AssistantPlatform",
                "AssistantCore",
                "AssistantPersistence",
                "MockPlatform",
                "AIProviderRemote",
                "AIProviderApple",
                "AIProviderLocal",
                "DevSupport",
            ]
        ),

        // MARK: Tests

        .testTarget(name: "AssistantDomainTests", dependencies: ["AssistantDomain"]),
        .testTarget(name: "SystemSurfacesTests", dependencies: ["SystemSurfaces"]),
        .testTarget(name: "AssistantToolsTests", dependencies: ["AssistantTools"]),
        .testTarget(name: "ExecutiveSupportTests", dependencies: ["ExecutiveSupport"]),
        .testTarget(
            name: "PersonalMemoryTests",
            dependencies: ["PersonalMemory", "AssistantDomain"]
        ),
        .testTarget(
            name: "PersonalMemoryAppleTests",
            dependencies: ["PersonalMemoryApple", "PersonalMemory"]
        ),
        .testTarget(
            name: "AssistantPersistenceTests",
            dependencies: ["AssistantPersistence", "AssistantDomain", "AssistantTools"]
        ),
        .testTarget(
            name: "AssistantPersistenceSwiftDataTests",
            dependencies: [
                "AssistantPersistenceSwiftData",
                "AssistantPersistence",
                "AssistantDomain",
                "AssistantTools",
                "ExecutiveSupport",
            ]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: [
                "AssistantDomain",
                "AssistantAI",
                "AssistantTools",
                "AssistantPlatform",
                "ExecutiveSupport",
                "AssistantCore",
                "MockPlatform",
                "AssistantPersistence",
                "PersonalMemory",
                "DevSupport",
                // For the provider-switch tests: the guarantee that selecting
                // the on-device model moves none of the user's data is a
                // property of the whole app, so it is asserted here rather
                // than inside the Apple provider's own tests.
                "AIProviderApple",
                // For the local-provider integration tests: the claim Part 10
                // makes is about everything *above* the provider being
                // unchanged, and only a test that can see the engine, the tool
                // pipeline and the local provider at once can assert it.
                "AIProviderLocal",
                // For the voice-pipeline tests. `AssistantVoice` cannot import
                // the engine — it depends on nothing in this package — so the
                // only place "a spoken sentence gets the whole pipeline" can be
                // asserted is where both are visible.
                "AssistantVoice",
                // For the system-surface tests: that a widget's Done really
                // reaches `TaskStatusMachine`, and that a snapshot carries no
                // credentials, are claims about the join between the two.
                "SystemSurfaces",
            ]
        ),
        .testTarget(
            name: "AssistantVoiceTests",
            dependencies: ["AssistantVoice"]
        ),
        .testTarget(
            name: "AssistantPlatformAppleTests",
            dependencies: [
                "AssistantDomain",
                "AssistantPlatform",
                "AssistantPlatformApple",
                "ExecutiveSupport",
            ]
        ),
        .testTarget(
            name: "AIProviderTests",
            dependencies: [
                "AssistantDomain",
                "AssistantAI",
                "AssistantTools",
                "AIProviderRemote",
                "AIProviderApple",
                "AIProviderLocal",
                "AIProviderLocalLlama",
                "AssistantPersistence",
                // For the Apple tool-safety tests: they assert that invoking a
                // Foundation Models tool adapter leaves the platform services
                // untouched, which needs something whose calls can be counted.
                "AssistantPlatform",
                "MockPlatform",
            ]
        ),
    ]
)
