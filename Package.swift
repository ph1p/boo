// swift-tools-version: 6.2
import PackageDescription

let booDeps: [Target.Dependency] = [
    "CGhostty",
    "CIronmark",
    .product(name: "Sparkle", package: "Sparkle")
]
let booExclude: [String] = [
    "App/Info.plist",
    "App/Boo.entitlements",
    "App/main.swift",
    "Resources/MonacoSource"
]
// Library search path — needed by every target that links against GhosttyKit.
let booLibrarySearchFlags: [String] = [
    "-L", "Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
]
// The runtime search path (rpath) only belongs on the final executable. Adding it to
// both the Boo library and BooApp made the linker emit a duplicate-rpath warning, since
// BooApp inherits the flag from its Boo dependency and adds its own.
let booLibLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(booLibrarySearchFlags)
]
let booExeLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        booLibrarySearchFlags + [
            "-Xlinker", "-rpath",
            "-Xlinker", "@executable_path/../Frameworks"
        ])
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
            .linkedLibrary("ghostty-internal-fat"),
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
        linkerSettings: booLibLinkerSettings
    ),
    .executableTarget(
        name: "BooApp",
        dependencies: ["Boo"],
        path: "BooApp",
        linkerSettings: booExeLinkerSettings
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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: allTargets
)
