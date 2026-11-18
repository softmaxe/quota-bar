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
        .systemLibrary(name: "CQuotaBarRust"),
        // Data layer: credentials, usage endpoints, snapshot models. No AppKit.
        .target(
            name: "QuotaBarCore",
            dependencies: ["CQuotaBarRust"],
            resources: [.copy("Resources/UsageReport"), .copy("Resources/Pricing")]
        ),
        // Menu bar UI, as a library so the test runner can drive it.
        .target(
            name: "QuotaBarApp",
            dependencies: ["QuotaBarCore"]
        ),
        // The app's entry point, and nothing else.
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarApp"]
        ),
        // Headless probe: prints what the providers return. Debugging aid, not shipped.
        .executableTarget(
            name: "QuotaBarProbe",
            dependencies: ["QuotaBarCore"]
        ),
        // Core and app regression checks use a plain assertion executable.
        .executableTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBarCore", "QuotaBarApp"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
