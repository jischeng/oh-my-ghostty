// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OMGMobile",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "OMGMobileCore", targets: ["OMGMobileCore"])],
    targets: [
        .systemLibrary(name: "GhosttyVt", path: "GhosttyVt"),
        .target(name: "OMGMobileCore", path: "Core"),
        .target(name: "OMGTerminal", dependencies: ["GhosttyVt"], path: "Vendor/Termio",
                exclude: ["LICENSE.termio", "StreamTerminalView.swift", "WebSocketLink.swift",
                          "RepeatingKeyButton.swift", "UPSTREAM.md"]),
        .testTarget(name: "OMGMobileCoreTests", dependencies: ["OMGMobileCore"], path: "Tests/Core"),
        .testTarget(name: "OMGTerminalTests", dependencies: ["OMGTerminal", "GhosttyVt"], path: "Tests/Terminal"),
    ]
)
