// swift-tools-version: 5.9
import PackageDescription

let extermDeps: [Target.Dependency] = ["CGhostty"]
let extermExclude: [String] = [
    "App/Info.plist",
    "App/Exterm.entitlements",
]
let extermLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L", "Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"])
]
let targets: [Target] = [
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
        dependencies: extermDeps,
        path: "Exterm",
        exclude: extermExclude,
        linkerSettings: extermLinkerSettings
    ),
    .testTarget(
        name: "ExtermTests",
        dependencies: ["Exterm"],
        path: "Tests/ExtermTests"
    ),
]

let package = Package(
    name: "Exterm",
    platforms: [
        .macOS(.v13)
    ],
    targets: targets
)
