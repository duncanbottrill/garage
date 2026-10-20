// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageKit",
    // `.v26` needs swift-tools 6.2; the string form keeps tools 6.0 with the same minimums.
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "GarageKit", targets: ["GarageKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "GarageKit",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GarageKitTests",
            dependencies: ["GarageKit"]
        ),
        .testTarget(
            name: "GarageKitSnapshotTests",
            dependencies: [
                "GarageKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ]
)
