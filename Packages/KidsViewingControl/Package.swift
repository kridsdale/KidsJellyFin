// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KidsViewingControl",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "KidsViewingControl", targets: ["KidsViewingControl"])],
    dependencies: [.package(path: "../KidsDomain"), .package(path: "../KidsParentControl")],
    targets: [
        .target(name: "KidsViewingControl", dependencies: ["KidsDomain", "KidsParentControl"]),
        .testTarget(name: "KidsViewingControlTests", dependencies: ["KidsViewingControl", "KidsDomain", "KidsParentControl"])
    ]
)
