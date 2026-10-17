// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KidsParentControl",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "KidsParentControl", targets: ["KidsParentControl"])],
    targets: [
        .target(name: "KidsParentControl"),
        .testTarget(name: "KidsParentControlTests", dependencies: ["KidsParentControl"], resources: [.copy("Fixtures")])
    ]
)
