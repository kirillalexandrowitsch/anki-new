// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CardsKit",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CardsCore", targets: ["CardsCore"]),
        .library(name: "CardsInfrastructure", targets: ["CardsInfrastructure"]),
        .library(name: "CardsDesignSystem", targets: ["CardsDesignSystem"]),
        .library(name: "CardsFeatures", targets: ["CardsFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs.git",
                 revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "CardsCore"),
        .target(name: "CardsInfrastructure", dependencies: [
            "CardsCore",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "FSRS", package: "swift-fsrs"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .target(name: "CardsDesignSystem", resources: [.process("Resources")]),
        .target(name: "CardsFeatures", dependencies: ["CardsCore", "CardsDesignSystem"],
                resources: [.process("Resources")]),
        .testTarget(name: "CardsDesignSystemTests", dependencies: ["CardsDesignSystem"]),
        // Test helpers are never a product or a dependency of an app/library target.
        .target(name: "CardsTestSupport", dependencies: ["CardsCore"], path: "Tests/Support"),
        .testTarget(name: "CardsCoreTests", dependencies: ["CardsCore", "CardsTestSupport"]),
        .testTarget(name: "CardsInfrastructureTests", dependencies: [
            "CardsInfrastructure",
            "CardsTestSupport",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "FSRS", package: "swift-fsrs"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], resources: [.copy("Fixtures")]),
        .testTarget(name: "CardsFeaturesTests", dependencies: ["CardsFeatures", "CardsCore", "CardsTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
