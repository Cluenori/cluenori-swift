// swift-tools-version: 6.2
import PackageDescription

// Cluenori's SDK for apps on Apple's platforms: a small core every app links, and opt-in modules for
// the parts whose inclusion has a cost (concept/Foundation.md, "One SDK for each platform, in
// modules"). Each library depends only on the core, and the core only on the generated client.
//
//   CluenoriUpdateGate, CluenoriAnalytics, CluenoriPerformance   opt-in: views, privacy label, MetricKit
//        └──────────────────────┬─────────────────────┘
//                            Cluenori                             core: sessions, queue, manifest, headers
//                               │
//                         CluenoriIngest                          generated client of the ingest API

// Every target: Swift 6, its concurrency checked. Warnings are errors in `./check` alone, never in
// an app's build, so a newer Xcode's new warning can't break an app that depends on this package.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The views run on the main actor unless they say otherwise; the rest is a library's: nonisolated,
// so the caller decides where it runs.
let onMainActor: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Cluenori",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Cluenori", targets: ["Cluenori"]),
        .library(name: "CluenoriAnalytics", targets: ["CluenoriAnalytics"]),
        .library(name: "CluenoriPerformance", targets: ["CluenoriPerformance"]),
        .library(name: "CluenoriUpdateGate", targets: ["CluenoriUpdateGate"]),
        .library(name: "CluenoriIngest", targets: ["CluenoriIngest"]),
    ],
    targets: [
        .target(name: "CluenoriIngest", swiftSettings: strict),
        .target(
            name: "Cluenori",
            dependencies: ["CluenoriIngest"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: strict
        ),
        .target(
            name: "CluenoriAnalytics",
            dependencies: ["Cluenori", "CluenoriIngest"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: strict
        ),
        .target(
            name: "CluenoriPerformance",
            dependencies: ["Cluenori", "CluenoriIngest"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: strict
        ),
        .target(
            name: "CluenoriUpdateGate",
            dependencies: ["Cluenori"],
            resources: [.process("Resources")],
            swiftSettings: onMainActor
        ),
        // A fake deployment, clock and folder for the tests, which drive an engine of their own.
        .target(
            name: "CluenoriTestSupport", dependencies: ["Cluenori", "CluenoriIngest"], path: "Tests/Support",
            swiftSettings: strict
        ),
        .testTarget(
            name: "CluenoriTests", dependencies: ["Cluenori", "CluenoriIngest", "CluenoriTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "CluenoriModulesTests",
            dependencies: [
                "CluenoriAnalytics", "CluenoriPerformance", "CluenoriUpdateGate", "Cluenori", "CluenoriIngest",
                "CluenoriTestSupport",
            ],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
