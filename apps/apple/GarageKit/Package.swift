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
        // Pinned to the minor line resolved when the scaffold landed; bump deliberately (and in README.md).
        .package(url: "https://github.com/supabase/supabase-swift", .upToNextMinor(from: "2.55.4")),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", .upToNextMinor(from: "1.19.6")),
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
            dependencies: [
                "GarageKit",
                // `AnyJSON` (the Realtime record type) is declared in the Supabase product.
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [.copy("Fixtures")]
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
