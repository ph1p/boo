// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let extermDeps: [Target.Dependency] = ["CGhostty"]
let extermExclude: [String] = [
    "App/Info.plist",
    "App/Exterm.entitlements",
    "Platform/Linux",
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
#else
let extermDeps: [Target.Dependency] = ["CLinuxGTK"]
let extermExclude: [String] = [
    // macOS-only directories
    "App",
    "Ghostty",
    "Renderer",
    "Views",
    "Platform/macOS",
    // macOS-only plugin implementations (UI layer)
    "Plugins",
    "Plugin/ScriptPluginAdapter.swift",
    "Plugin/ViewDSL/DSLRenderer.swift",
    "Plugin/ViewDSL/DSLActionHandler.swift",
    "Plugin/PluginWatcher.swift",
    // macOS-only services
    "Services/ContextAnnouncementEngine.swift",
    "Services/StatusBarPlugin.swift",
    "Services/FileSystemWatcher.swift",
    "Services/RemoteSessionMonitor.swift",
    "Services/RemoteExplorer.swift",
    "Services/RemoteShellInjector.swift",
    "Services/SSHControlManager.swift",
    "Services/TerminalBridge.swift",
    "Services/TerminalBridge+Heuristics.swift",
    "Services/TerminalBridge+Identity.swift",
    // macOS-only models
    "Models/Theme.swift",
    "Models/Settings.swift",
    "Models/Workspace.swift",
    "Models/SplitTree.swift",
    "Models/Pane.swift",
    "Models/AppState.swift",
    // macOS-only plugin framework files (depend on AppKit/SwiftUI types)
    "Plugin/ExtermPluginProtocol.swift",
    "Plugin/PluginRegistry.swift",
    "Plugin/PluginRuntime.swift",
    "Plugin/JSCRuntime.swift",
    "Plugin/DensityMetrics.swift",
    "Plugin/TerminalContext.swift",
    "Plugin/WhenClause.swift",
    "Plugin/EnrichmentContext.swift",
    "Plugin/PluginHostActions.swift",
    "Plugin/PluginStateBag.swift",
    "Plugin/ScriptExecutor.swift",
    "Plugin/PluginManifest.swift",
    "Terminal",
]
let extermLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("gtk-4"),
    .linkedLibrary("vte-2.91-gtk4"),
    .linkedLibrary("json-glib-1.0"),
    .linkedLibrary("gobject-2.0"),
    .linkedLibrary("glib-2.0"),
]
let targets: [Target] = [
    .target(
        name: "CLinuxGTK",
        path: "CLinuxGTK",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("include"),
            .unsafeFlags([
                "-I/usr/include/gtk-4.0",
                "-I/usr/include/glib-2.0",
                "-I/usr/lib/x86_64-linux-gnu/glib-2.0/include",
                "-I/usr/lib/aarch64-linux-gnu/glib-2.0/include",
                "-I/usr/include/pango-1.0",
                "-I/usr/include/harfbuzz",
                "-I/usr/include/cairo",
                "-I/usr/include/gdk-pixbuf-2.0",
                "-I/usr/include/graphene-1.0",
                "-I/usr/lib/x86_64-linux-gnu/graphene-1.0/include",
                "-I/usr/lib/aarch64-linux-gnu/graphene-1.0/include",
                "-I/usr/include/vte-2.91",
                "-I/usr/include/json-glib-1.0",
            ]),
        ]
    ),
    .executableTarget(
        name: "Exterm",
        dependencies: extermDeps,
        path: "Exterm",
        exclude: extermExclude,
        linkerSettings: extermLinkerSettings
    ),
]
#endif

let package = Package(
    name: "Exterm",
    platforms: [
        .macOS(.v13)
    ],
    targets: targets
)
