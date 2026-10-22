// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"]),
        .executable(name: "QuotaBarProbe", targets: ["QuotaBarProbe"]),
        .executable(name: "QuotaBarTests", targets: ["QuotaBarTests"]),
        .library(name: "QuotaBarCore", targets: ["QuotaBarCore"]),
    ],
    targets: [
        // Data layer: credentials, usage endpoints, snapshot models. No AppKit.
        .target(
            name: "QuotaBarCore",
            resources: [.copy("Resources/UsageReport"), .copy("Resources/Pricing")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar UI, as a library so the test runner can drive it.
        .target(
            name: "QuotaBarApp",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app's entry point, and nothing else.
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Headless probe: prints what the providers return. Debugging aid, not shipped.
        .executableTarget(
            name: "QuotaBarProbe",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Core and app regression checks use a plain assertion executable.
        .executableTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBarCore", "QuotaBarApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
