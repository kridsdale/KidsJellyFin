// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KidsApplication",
    platforms: [.iOS(.v17), .tvOS(.v17)],
    products: [.library(name: "KidsApplication", targets: ["KidsApplication"])],
    dependencies: [
        .package(path: "../KidsAccounts"),
        .package(path: "../KidsArtwork"),
        .package(path: "../KidsArtworkUI"),
        .package(path: "../KidsCatalog"),
        .package(path: "../KidsDiagnostics"),
        .package(path: "../KidsDomain"),
        .package(path: "../KidsPersistence"),
        .package(path: "../KidsPlaybackSession"),
        .package(path: "../KidsParentControl"), .package(path: "../KidsViewingControl")
    ],
    targets: [
        .target(name: "KidsApplication", dependencies: [
            .product(name: "KidsAccounts", package: "KidsAccounts"),
            .product(name: "KidsArtwork", package: "KidsArtwork"),
            .product(name: "KidsArtworkUI", package: "KidsArtworkUI"),
            .product(name: "KidsCatalog", package: "KidsCatalog"),
            .product(name: "KidsDiagnostics", package: "KidsDiagnostics"),
            .product(name: "KidsDomain", package: "KidsDomain"),
            .product(name: "KidsPersistence", package: "KidsPersistence"),
            .product(name: "KidsPlaybackSession", package: "KidsPlaybackSession"),
            .product(name: "KidsParentControl", package: "KidsParentControl"), .product(
                name: "KidsViewingControl",
                package: "KidsViewingControl"
            )
        ]),
        .testTarget(
            name: "KidsApplicationTests",
            dependencies: [
                "KidsApplication",
                .product(name: "KidsAccounts", package: "KidsAccounts"),
                .product(name: "KidsCatalog", package: "KidsCatalog"),
                .product(name: "KidsDiagnostics", package: "KidsDiagnostics"),
                .product(name: "KidsDomain", package: "KidsDomain"),
                .product(name: "KidsParentControl", package: "KidsParentControl"),
                .product(name: "KidsPlaybackSession", package: "KidsPlaybackSession")
            ]
        )
    ]
)
