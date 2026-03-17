// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Exterm",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CPTYHelper",
            path: "CPTYHelper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedLibrary("util")
            ]
        ),
        .executableTarget(
            name: "Exterm",
            dependencies: ["CPTYHelper"],
            path: "Exterm",
            exclude: ["App/Info.plist", "Renderer/Shaders.metal"]
        ),
        .testTarget(
            name: "ExtermTests",
            dependencies: ["Exterm"],
            path: "Tests/ExtermTests"
        )
    ]
)
