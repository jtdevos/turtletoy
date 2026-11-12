// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TurtleToy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TurtleToyCore", targets: ["TurtleToyCore"]),
        .executable(name: "TurtleToy", targets: ["TurtleToy"])
    ],
    targets: [
        .target(
            name: "TurtleToyCore",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "TurtleToy",
            dependencies: ["TurtleToyCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "TurtleToyTests",
            dependencies: ["TurtleToyCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
