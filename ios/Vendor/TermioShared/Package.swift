// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TermioShared",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "TermioShared", targets: ["TermioShared"])],
    dependencies: [.package(path: "../Highlightr")],
    targets: [
        .target(name: "TermioShared", dependencies: [
            .product(name: "Highlightr", package: "Highlightr", condition: .when(platforms: [.iOS])),
        ], resources: [.process("Resources")]),
    ]
)
