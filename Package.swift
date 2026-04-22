// swift-tools-version: 6.3
import PackageDescription

let booDeps: [Target.Dependency] = [
    "CGhostty",
    "CIronmark"
]
let booExclude: [String] = [
    "App/Info.plist",
    "App/Boo.entitlements",
    "App/main.swift",
    "Resources/MonacoSource"
]
let booLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L", "Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"])
]

let allTargets: [Target] = [
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
            .linkedFramework("Carbon")
        ]
    ),
    .target(
        name: "CIronmark",
        path: "CIronmark",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("include")
        ],
        linkerSettings: [
            .unsafeFlags(["-L", "Vendor/ironmark/macos-arm64"]),
            .linkedLibrary("ironmark")
        ]
    ),
    .target(
        name: "Boo",
        dependencies: booDeps,
        path: "Boo",
        exclude: booExclude,
        resources: [
            .copy("Resources/Images"),
            .copy("Resources/MonacoBundle")
        ],
        linkerSettings: booLinkerSettings
    ),
    .executableTarget(
        name: "BooApp",
        dependencies: ["Boo"],
        path: "BooApp",
        linkerSettings: booLinkerSettings
    ),
    .testTarget(
        name: "BooTests",
        dependencies: ["Boo"],
        path: "Tests/BooTests"
    )
]

let package = Package(
    name: "Boo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Boo", targets: ["Boo"]),
        .executable(name: "BooApp", targets: ["BooApp"])
    ],
    dependencies: [],
    targets: allTargets
)
