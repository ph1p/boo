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
        .target(
            name: "CGhostty",
            path: "CGhostty",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"]),
                .linkedLibrary("ghostty-fat"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "Exterm",
            dependencies: ["CPTYHelper", "CGhostty"],
            path: "Exterm",
            exclude: ["App/Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"]),
            ]
        ),
        .testTarget(
            name: "ExtermTests",
            dependencies: ["Exterm"],
            path: "Tests/ExtermTests"
        )
    ]
)
