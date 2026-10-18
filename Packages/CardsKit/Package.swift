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
    targets: [
        .target(name: "CardsCore"),
        .target(name: "CardsInfrastructure", dependencies: ["CardsCore"]),
        .target(name: "CardsDesignSystem"),
        .target(name: "CardsFeatures", dependencies: ["CardsCore", "CardsDesignSystem"],
                resources: [.process("Resources")]),
        .testTarget(name: "CardsCoreTests", dependencies: ["CardsCore"]),
        .testTarget(name: "CardsInfrastructureTests", dependencies: ["CardsInfrastructure"]),
        .testTarget(name: "CardsFeaturesTests", dependencies: ["CardsFeatures", "CardsCore"]),
    ],
    swiftLanguageModes: [.v6]
)
