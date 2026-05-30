// swift-tools-version: 6.3
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Nehir",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "Nehir",
            targets: ["NehirApp"]
        ),
        .executable(
            name: "nehirctl",
            targets: ["NehirCtl"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "NehirIPC",
            path: "Sources/NehirIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "Nehir",
            dependencies: [
                "NehirIPC",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/Nehir",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.C),
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .executableTarget(
            name: "NehirApp",
            dependencies: ["Nehir"],
            path: "Sources/NehirApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "NehirCtl",
            dependencies: ["NehirIPC"],
            path: "Sources/NehirCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "NehirTests",
            dependencies: ["Nehir", "NehirIPC", "NehirCtl"],
            path: "Tests/NehirTests",
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
