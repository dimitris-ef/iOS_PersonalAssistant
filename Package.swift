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
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "MockPlatform", targets: ["MockPlatform"]),
        // The real iPhone: EventKit, UserNotifications, AlarmKit. Apple-only
        // in practice — every framework import is behind `#if canImport`, so
        // the target still builds on Linux and Windows, where it contains only
        // the mapping layer.
        .library(name: "AssistantPlatformApple", targets: ["AssistantPlatformApple"]),
        .library(name: "AIProviderRemote", targets: ["AIProviderRemote"]),
        .library(name: "AIProviderApple", targets: ["AIProviderApple"]),
        .library(name: "AIProviderLocal", targets: ["AIProviderLocal"]),
        // Development-only. Exposed as a product so the iOS app target can use
        // the scripted stand-in while no real provider is implemented; drop it
        // from the app's dependencies once one is.
        .library(name: "DevSupport", targets: ["DevSupport"]),
        .executable(name: "assistant-dev", targets: ["DevHarness"]),
    ],
    targets: [
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

        // MARK: AI providers

        .target(name: "AIProviderRemote", dependencies: ["AssistantDomain", "AssistantAI"]),
        .target(name: "AIProviderApple", dependencies: ["AssistantDomain", "AssistantAI"]),
        .target(name: "AIProviderLocal", dependencies: ["AssistantDomain", "AssistantAI"]),

        // MARK: Development-only

        .target(
            name: "DevSupport",
            dependencies: ["AssistantDomain", "AssistantAI", "AssistantTools"]
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
        .testTarget(name: "AssistantToolsTests", dependencies: ["AssistantTools"]),
        .testTarget(name: "ExecutiveSupportTests", dependencies: ["ExecutiveSupport"]),
        .testTarget(
            name: "PersonalMemoryTests",
            dependencies: ["PersonalMemory", "AssistantDomain"]
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
            ]
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
                // For the Apple tool-safety tests: they assert that invoking a
                // Foundation Models tool adapter leaves the platform services
                // untouched, which needs something whose calls can be counted.
                "AssistantPlatform",
                "MockPlatform",
            ]
        ),
    ]
)
