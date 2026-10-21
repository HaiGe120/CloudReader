// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudReaderKit",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "CloudReaderCore", targets: ["CloudReaderCore"])
    ],
    targets: [
        .target(name: "CloudReaderCore"),
        .testTarget(name: "CloudReaderCoreTests", dependencies: ["CloudReaderCore"])
    ]
)
