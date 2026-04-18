import Foundation
import os.log

/// Watches `~/.boo/plugins/` for new, modified, and deleted plugin folders.
/// Hot-loads/unloads plugins via PluginRegistry.
@MainActor final class PluginWatcher {

    private let pluginsPath: String
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.3
    private let logger = Logger(subsystem: "com.boo", category: "PluginWatcher")

    /// Callback when a plugin is loaded/reloaded.
    var onPluginLoaded: ((String) -> Void)?  // plugin name
    /// Callback when a plugin is removed.
    var onPluginRemoved: ((String) -> Void)?  // plugin name
    /// Callback when a plugin fails to load.
    var onPluginError: ((String, String) -> Void)?  // folder name, error message

    /// Registry to register/unregister plugins with.
    weak var registry: PluginRegistry?

    /// Track loaded plugin folders to detect additions/removals.
    private var loadedPlugins: [String: PluginManifest] = [:]

    init() {
        let configDir = BooPaths.configDir
        self.pluginsPath = (configDir as NSString).appendingPathComponent("plugins")
    }

    /// Start watching the plugins directory.
    @MainActor
    func start() {
        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: pluginsPath, withIntermediateDirectories: true)

        // Initial scan
        scanPlugins()

        // Start FSEvents
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let pathsToWatch = [pluginsPath] as CFArray
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<PluginWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleScan()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            logger.info("Watching plugins at \(self.pluginsPath)")
        }
    }

    /// Stop watching.
    nonisolated func stop() {
        debounceTimer?.invalidate()
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func scheduleScan() {
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: self?.debounceInterval ?? 0.3, repeats: false)
            { [weak self] _ in
                Task { @MainActor in
                    self?.scanPlugins()
                }
            }
        }
    }

    @MainActor
    private func scanPlugins() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: pluginsPath) else { return }

        var currentFolders = Set<String>()

        for entry in entries {
            let folderPath = (pluginsPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            currentFolders.insert(entry)

            let manifestPath = (folderPath as NSString).appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestPath) else {
                if loadedPlugins[entry] != nil {
                    // Manifest removed — unload
                    unloadPlugin(folder: entry)
                }
                continue
            }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
                var manifest = try PluginManifest.parse(from: data)
                manifest.isExternal = true
                manifest.folderName = entry
                // External plugins always get a sidebar tab — no need to declare it in plugin.json
                if manifest.capabilities == nil {
                    manifest.capabilities = PluginManifest.Capabilities(
                        statusBarSegment: nil, sidebarTab: true)
                } else {
                    manifest.capabilities?.sidebarTab = true
                }

                if loadedPlugins[entry] == nil {
                    // New plugin
                    loadPlugin(manifest: manifest, folderPath: folderPath, folder: entry)
                } else if loadedPlugins[entry] != manifest {
                    // Changed manifest — reload
                    unloadPlugin(folder: entry)
                    loadPlugin(manifest: manifest, folderPath: folderPath, folder: entry)
                }
            } catch {
                logger.error("Plugin \(entry): \(error.localizedDescription)")
                onPluginError?(entry, "\(error)")
                if loadedPlugins[entry] != nil {
                    unloadPlugin(folder: entry)
                }
            }
        }

        // Detect removed folders
        for folder in loadedPlugins.keys where !currentFolders.contains(folder) {
            unloadPlugin(folder: folder)
        }
    }

    @MainActor
    private func loadPlugin(manifest: PluginManifest, folderPath: String, folder: String) {
        let adapter = ScriptPluginAdapter(manifest: manifest, folderPath: folderPath)
        registry?.register(adapter)
        loadedPlugins[folder] = manifest
        logger.info("Loaded plugin: \(manifest.name) (\(manifest.id))")
        onPluginLoaded?(manifest.name)
    }

    @MainActor
    private func unloadPlugin(folder: String) {
        guard let manifest = loadedPlugins.removeValue(forKey: folder) else { return }
        registry?.unregister(pluginID: manifest.id)
        logger.info("Unloaded plugin: \(manifest.name) (\(manifest.id))")
        onPluginRemoved?(manifest.name)
    }

    deinit {
        stop()
    }
}
