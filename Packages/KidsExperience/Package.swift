// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KidsExperience",
    platforms: [.tvOS("26.1")],
    products: [.library(name: "KidsExperience", targets: ["KidsExperience"])],
    dependencies: [
        .package(path: "../KidsAccounts"),
        .package(path: "../KidsApplication"),
        .package(path: "../KidsCatalog"),
        .package(path: "../KidsDiagnostics"),
        .package(path: "../KidsDiagnosticsUI"),
        .package(path: "../KidsDomain"),
        .package(path: "../KidsPlaybackSession"),
        .package(path: "../KidsServerDiscovery"),
        .package(path: "../SwiftfinUIState")
    ],
    targets: [.target(name: "KidsExperience", dependencies: [
        .product(name: "KidsAccounts", package: "KidsAccounts"),
        .product(name: "KidsApplication", package: "KidsApplication"),
        .product(name: "KidsCatalog", package: "KidsCatalog"),
        .product(name: "KidsDiagnostics", package: "KidsDiagnostics"),
        .product(name: "KidsDiagnosticsUI", package: "KidsDiagnosticsUI"),
        .product(name: "KidsDomain", package: "KidsDomain"),
        .product(name: "KidsPlaybackSession", package: "KidsPlaybackSession"),
        .product(name: "KidsServerDiscovery", package: "KidsServerDiscovery"),
        .product(name: "SwiftfinUIState", package: "SwiftfinUIState")
    ])]
)
