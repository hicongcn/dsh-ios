// swift-tools-version: 6.0
import PackageDescription

// The iOS client for DeepSeek Harness.
//
// Two independent targets:
//   DSHKit           — the wire protocol for talking to a `dsh web` host.
//   DSHAssetServer   — the loopback asset server that lets the standalone app
//                      run the harness entirely on device.
//
// Neither depends on iOS-only APIs, so both build and self-test on macOS, which
// keeps the protocol layer verifiable without Xcode.
let package = Package(
    name: "DSHKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .library(name: "DSHAssetServer", targets: ["DSHAssetServer"]),
        .executable(name: "dshkit-selftest", targets: ["DSHKitSelfTest"]),
        .executable(name: "dsh-asset-server-selftest", targets: ["DSHAssetServerSelfTest"]),
    ],
    targets: [
        .target(name: "DSHKit", path: "Sources/DSHKit"),
        .target(name: "DSHAssetServer", path: "Sources/DSHAssetServer"),
        .executableTarget(
            name: "DSHKitSelfTest",
            dependencies: ["DSHKit"],
            path: "Sources/DSHKitSelfTest"
        ),
        .executableTarget(
            name: "DSHAssetServerSelfTest",
            dependencies: ["DSHAssetServer"],
            path: "Sources/DSHAssetServerSelfTest"
        ),
    ]
)
