// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VerifiedCallKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "VerifiedCallKit", targets: ["VerifiedCallKit"]),
        .executable(name: "VerifiedCallDemo", targets: ["VerifiedCallDemo"])
    ],
    targets: [
        .target(
            name: "VerifiedCallKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "VerifiedCallDemo",
            dependencies: ["VerifiedCallKit"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "VerifiedCallKitTests",
            dependencies: ["VerifiedCallKit"]
        )
    ]
)
