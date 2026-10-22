// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KidsServerDiscovery",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "KidsServerDiscovery", targets: ["KidsServerDiscovery"])],
    dependencies: [.package(path: "../SwiftfinNetworking")],
    targets: [
        .target(name: "KidsServerDiscovery", dependencies: ["SwiftfinNetworking"]),
        .testTarget(name: "KidsServerDiscoveryTests", dependencies: ["KidsServerDiscovery"])
    ]
)
