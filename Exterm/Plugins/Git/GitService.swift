import Foundation

// MARK: - Git Command Execution & Detection

extension GitPlugin {

    /// Run a git command synchronously in the given repo. Used for stage/unstage/discard/stash.
    @discardableResult
    nonisolated static func runGitCommand(repoRoot: String, args: [String]) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot] + args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - Detection Helpers

    nonisolated static func detectChangedFiles(repoRoot: String) -> [GitChangedFile] {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "status", "--porcelain=v1"]
        task.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
            return []
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let str = String(line)
            guard str.count >= 3 else { return nil }
            let col1 = str[str.startIndex]       // index status
            let col2 = str[str.index(after: str.startIndex)] // work-tree status
            let filePath = String(str.dropFirst(3))
            let fullPath = (repoRoot as NSString).appendingPathComponent(filePath)
            return GitChangedFile(
                path: filePath,
                indexStatus: col1,
                workTreeStatus: col2,
                fullPath: fullPath
            )
        }
    }

    nonisolated static func detectStashCount(repoRoot: String) -> Int {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "stash", "list"]
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return 0 }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return 0 }
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    nonisolated static func detectAheadBehind(repoRoot: String) -> (ahead: Int, behind: Int) {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return (0, 0) }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return (0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (0, 0)
        }
        let parts = output.split(separator: "\t")
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else {
            return (0, 0)
        }
        return (ahead, behind)
    }

    nonisolated static func detectLastCommit(repoRoot: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "log", "-1", "--format=%h %s"]
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }
        return output
    }

    // MARK: - Refresh & Watcher

    internal func refreshGitStatus(cwd: String, repoRoot: String?) {
        guard let root = repoRoot else {
            cachedFiles = []
            cachedStashCount = 0
            cachedAheadCount = 0
            cachedBehindCount = 0
            cachedLastCommit = nil
            lastRefreshedPath = cwd
            repoWatcher?.stop()
            repoWatcher = nil
            gitDirWatcher?.stop()
            gitDirWatcher = nil
            return
        }
        lastRefreshedPath = cwd
        setupGitWatcher(repoRoot: root)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            var files: [GitChangedFile] = []
            var stashCount = 0
            var aheadCount = 0
            var behindCount = 0
            var lastCommit: String?

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                files = Self.detectChangedFiles(repoRoot: root)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stashCount = Self.detectStashCount(repoRoot: root)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let (a, b) = Self.detectAheadBehind(repoRoot: root)
                aheadCount = a
                behindCount = b
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                lastCommit = Self.detectLastCommit(repoRoot: root)
                group.leave()
            }

            group.wait()
            DispatchQueue.main.async {
                guard let self = self else { return }
                let changed = self.cachedFiles.map(\.path) != files.map(\.path)
                    || self.cachedStashCount != stashCount
                    || self.cachedAheadCount != aheadCount
                    || self.cachedBehindCount != behindCount
                    || self.cachedLastCommit != lastCommit
                self.cachedFiles = files
                self.cachedStashCount = stashCount
                self.cachedAheadCount = aheadCount
                self.cachedBehindCount = behindCount
                self.cachedLastCommit = lastCommit
                if changed {
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    internal func setupGitWatcher(repoRoot: String) {
        guard watchedRepoRoot != repoRoot else { return }
        watchedRepoRoot = repoRoot
        repoWatcher?.stop()
        gitDirWatcher?.stop()

        let debouncedRefresh: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.refreshGitStatus(cwd: self.lastRefreshedPath ?? repoRoot, repoRoot: repoRoot)
            }
            self.debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        repoWatcher = FileSystemWatcher(path: repoRoot, onChange: debouncedRefresh)
        repoWatcher?.start()

        let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir) {
            gitDirWatcher = FileSystemWatcher(path: gitDir, onChange: debouncedRefresh)
            gitDirWatcher?.start()
        }
    }
}
