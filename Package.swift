// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AlaudCore",
    platforms: [.macOS(.v15), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "AlaudCore", targets: ["AlaudCore"])],
    targets: [
        .target(name: "AlaudCore", path: "Sources/Core"),
        .testTarget(name: "AlaudCoreTests", dependencies: ["AlaudCore"], path: "Tests/Core")
    ],
    swiftLanguageModes: [.v5]
)
