// swift-tools-version: 5.9
import PackageDescription

let booDeps: [Target.Dependency] = ["CGhostty"]
let booExclude: [String] = [
    "App/Info.plist",
    "App/Boo.entitlements",
]
let booLinkerSettings: [LinkerSetting] = [
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
        name: "Boo",
        dependencies: booDeps,
        path: "Boo",
        exclude: booExclude,
        linkerSettings: booLinkerSettings
    ),
    .testTarget(
        name: "BooTests",
        dependencies: ["Boo"],
        path: "Tests/BooTests"
    ),
]

let package = Package(
    name: "Boo",
    platforms: [
        .macOS(.v13)
    ],
    targets: targets
)
