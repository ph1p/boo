import Cocoa

/// Lightweight auto-updater that checks GitHub Releases for new versions,
/// downloads the DMG, and replaces the running app.
@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    // MARK: - Configuration

    /// Set these to your GitHub repository coordinates.
    static let repoOwner = "ph1p"
    static let repoName = "exterm"

    // MARK: - State

    enum State: Equatable {
        case idle
        case checking
        case available(release: Release)
        case downloading(progress: Double)
        case readyToInstall(dmgURL: URL)
        case installing
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.installing, .installing): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            case (.available(let a), .available(let b)): return a.tagName == b.tagName
            case (.readyToInstall(let a), .readyToInstall(let b)): return a == b
            default: return false
            }
        }
    }

    struct Release: Codable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String
        let assets: [Asset]

        struct Asset: Codable {
            let name: String
            let browserDownloadUrl: String
            let size: Int
        }

        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }

        var dmgAsset: Asset? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        }
    }

    @Published private(set) var state: State = .idle

    private var downloadTask: URLSessionDataTask?

    // MARK: - Version Info

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Check

    func checkForUpdates(userInitiated: Bool = false) async {
        guard state != .checking else { return }

        // Respect check interval for automatic checks
        if !userInitiated {
            guard AppSettings.shared.autoCheckUpdates else { return }
            if let last = AppSettings.shared.lastUpdateCheck,
                Date().timeIntervalSince(last) < 86400
            {
                return
            }
        }

        state = .checking
        let urlString =
            "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            state = .error("Invalid repository URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            AppSettings.shared.lastUpdateCheck = Date()

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = userInitiated ? .error("No releases found") : .idle
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let release = try? decoder.decode(Release.self, from: data) else {
                state = userInitiated ? .error("Failed to parse release") : .idle
                return
            }

            guard release.dmgAsset != nil else {
                state = userInitiated ? .error("No DMG in release") : .idle
                return
            }

            if Self.isNewer(release.version, than: Self.currentVersion) {
                if !userInitiated, AppSettings.shared.skipVersion == release.version {
                    state = .idle
                    return
                }
                state = .available(release: release)
            } else {
                state = .idle
                if userInitiated {
                    showUpToDateAlert()
                }
            }
        } catch {
            state = userInitiated ? .error(error.localizedDescription) : .idle
        }
    }

    // MARK: - Download

    func downloadUpdate(_ release: Release) {
        guard let asset = release.dmgAsset,
            let url = URL(string: asset.browserDownloadUrl)
        else {
            state = .error("No download URL")
            return
        }

        state = .downloading(progress: 0)

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.exterm.app/Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let destURL = cacheDir.appendingPathComponent(asset.name)

        // Clean up previous downloads
        try? FileManager.default.removeItem(at: destURL)

        let delegate = DownloadDelegate { [weak self] progress in
            DispatchQueue.main.async { self?.state = .downloading(progress: progress) }
        } completion: { [weak self] tempURL, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.state = .error(error.localizedDescription)
                    return
                }
                guard let tempURL else {
                    self.state = .error("Download failed")
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    self.state = .readyToInstall(dmgURL: destURL)
                } catch {
                    self.state = .error("Failed to save: \(error.localizedDescription)")
                }
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    // MARK: - Install

    func installAndRelaunch(dmgURL: URL) {
        state = .installing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let appURL = try Self.extractAppFromDMG(dmgURL)

                // Verify code signature
                guard Self.verifyCodeSignature(at: appURL) else {
                    DispatchQueue.main.async {
                        self?.state = .error("Code signature verification failed")
                    }
                    return
                }

                let currentAppURL = Bundle.main.bundleURL
                let script = Self.buildReplacementScript(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    currentApp: currentAppURL.path,
                    newApp: appURL.path
                )

                DispatchQueue.main.async {
                    Self.launchReplacementScript(script)
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .error("Install failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func skipVersion(_ version: String) {
        AppSettings.shared.skipVersion = version
        state = .idle
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - DMG Handling

    nonisolated private static func extractAppFromDMG(_ dmgURL: URL) throws -> URL {
        // Mount DMG
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        let pipe = Pipe()
        mountProcess.standardOutput = pipe
        try mountProcess.run()
        mountProcess.waitUntilExit()

        guard mountProcess.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        let plistData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.first(where: { $0["mount-point"] != nil })?["mount-point"] as? String
        else {
            throw UpdateError.mountFailed
        }

        // Find .app in mounted volume
        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try FileManager.default.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            // Unmount before throwing
            let unmount = Process()
            unmount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            unmount.arguments = ["detach", mountPoint, "-quiet"]
            try? unmount.run()
            unmount.waitUntilExit()
            throw UpdateError.noAppInDMG
        }

        // Copy to staging area
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ExTermUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedApp = staging.appendingPathComponent(appBundle.lastPathComponent)
        try FileManager.default.copyItem(at: appBundle, to: stagedApp)

        // Unmount
        let unmount = Process()
        unmount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        unmount.arguments = ["detach", mountPoint, "-quiet"]
        try? unmount.run()
        unmount.waitUntilExit()

        return stagedApp
    }

    nonisolated private static func verifyCodeSignature(at appURL: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--deep", "--strict", appURL.path]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - Replacement Script

    nonisolated private static func buildReplacementScript(pid: Int32, currentApp: String, newApp: String) -> String {
        """
        #!/bin/bash
        # Wait for Exterm to exit
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        # Remove quarantine from downloaded app
        xattr -dr com.apple.quarantine "\(newApp)" 2>/dev/null
        # Replace app bundle
        rm -rf "\(currentApp)"
        cp -R "\(newApp)" "\(currentApp)"
        # Clean up staging
        rm -rf "$(dirname "\(newApp)")"
        # Relaunch
        open "\(currentApp)"
        # Self-destruct
        rm -- "$0"
        """
    }

    private static func launchReplacementScript(_ script: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exterm-update-\(UUID().uuidString).sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = nil
        process.standardError = nil
        // Detach so it outlives the parent
        try? process.run()
    }

    // MARK: - Version Comparison

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - UI Helpers

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Exterm \(Self.currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case mountFailed
        case noAppInDMG

        var errorDescription: String? {
            switch self {
            case .mountFailed: return "Failed to mount DMG"
            case .noAppInDMG: return "No app found in DMG"
            }
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onCompletion: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, completion: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onCompletion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onCompletion(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onCompletion(nil, error) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
