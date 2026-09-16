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
            resources: [.copy("Resources/UsageReport")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar UI.
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Headless probe: prints what the providers return. Debugging aid, not shipped.
        .executableTarget(
            name: "QuotaBarProbe",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ship no XCTest, so the suite is a plain executable.
        .executableTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
