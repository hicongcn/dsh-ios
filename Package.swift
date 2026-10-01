// swift-tools-version: 6.0
import PackageDescription

// The iOS client kit for DeepSeek Harness.
//
// DSHKit is the platform-neutral protocol layer, so it builds and self-tests on
// macOS without an iOS SDK present. The SwiftUI application in Apps/ is a thin
// consumer built by Xcode against the same sources.
let package = Package(
    name: "DSHKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .executable(name: "dshkit-selftest", targets: ["DSHKitSelfTest"]),
    ],
    targets: [
        .target(name: "DSHKit", path: "Sources/DSHKit"),
        .executableTarget(name: "DSHKitSelfTest", dependencies: ["DSHKit"], path: "Sources/DSHKitSelfTest"),
    ]
)
