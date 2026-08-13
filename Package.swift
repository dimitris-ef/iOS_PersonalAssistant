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
    // TODO-XCODE: raise the iOS minimum once we adopt Apple Foundation Models
    // and AlarmKit, both of which require a newer deployment target.
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AssistantDomain", targets: ["AssistantDomain"]),
        .library(name: "AssistantAI", targets: ["AssistantAI"]),
        .library(name: "AssistantTools", targets: ["AssistantTools"]),
        .library(name: "AssistantPlatform", targets: ["AssistantPlatform"]),
        .library(name: "AssistantPersistence", targets: ["AssistantPersistence"]),
        .library(name: "ExecutiveSupport", targets: ["ExecutiveSupport"]),
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "MockPlatform", targets: ["MockPlatform"]),
        .library(name: "AIProviderRemote", targets: ["AIProviderRemote"]),
        .library(name: "AIProviderApple", targets: ["AIProviderApple"]),
        .library(name: "AIProviderLocal", targets: ["AIProviderLocal"]),
        .executable(name: "assistant-dev", targets: ["DevHarness"]),
    ],
    targets: [
        // MARK: Core

        .target(name: "AssistantDomain"),

        .target(name: "AssistantAI", dependencies: ["AssistantDomain"]),

        .target(name: "AssistantTools", dependencies: ["AssistantDomain"]),

        .target(name: "AssistantPlatform", dependencies: ["AssistantDomain"]),

        .target(name: "AssistantPersistence", dependencies: ["AssistantDomain"]),

        .target(name: "ExecutiveSupport", dependencies: ["AssistantDomain"]),

        .target(
            name: "AssistantCore",
            dependencies: [
                "AssistantDomain",
                "AssistantAI",
                "AssistantTools",
                "AssistantPlatform",
                "AssistantPersistence",
                "ExecutiveSupport",
            ]
        ),

        // MARK: Platform implementations

        .target(name: "MockPlatform", dependencies: ["AssistantDomain", "AssistantPlatform"]),

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
        .testTarget(name: "AssistantPersistenceTests", dependencies: ["AssistantPersistence"]),
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
                "DevSupport",
            ]
        ),
        .testTarget(
            name: "AIProviderTests",
            dependencies: [
                "AssistantAI",
                "AIProviderRemote",
                "AIProviderApple",
                "AIProviderLocal",
            ]
        ),
    ]
)
