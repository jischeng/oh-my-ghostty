// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMGMobile",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "OMGMobileCore", targets: ["OMGMobileCore"])],
    dependencies: [.package(path: "Vendor/TermioShared")],
    targets: [
        .systemLibrary(name: "GhosttyVt", path: "GhosttyVt"),
        .target(name: "OMGMobileCore", path: "Core"),
        .target(name: "OMGTerminal", dependencies: [
            "GhosttyVt", .product(name: "TermioShared", package: "TermioShared"),
        ], path: "Vendor/TermioStream"),
        .testTarget(name: "OMGMobileCoreTests", dependencies: ["OMGMobileCore"], path: "Tests/Core"),
        .testTarget(name: "OMGTerminalTests", dependencies: ["OMGTerminal", "GhosttyVt"], path: "Tests/Terminal"),
    ]
)
