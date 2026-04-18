import Foundation

// MARK: - Process Timeout Helper

extension Process {
    /// Launch the process and wait for it to exit, terminating it if it exceeds the timeout.
    /// `terminationHandler` is set before `run()` to eliminate the race where a fast-exiting
    /// process finishes before the handler is registered, leaving the semaphore unsignalled.
    /// Returns true if the process exited within the timeout with status 0.
    @discardableResult
    func runAndWait(seconds: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        terminationHandler = { _ in sem.signal() }
        do { try run() } catch { return false }
        let result = sem.wait(timeout: .now() + seconds)
        if result == .timedOut {
            terminate()
            return false
        }
        return terminationStatus == 0
    }
}

// MARK: - Git Command Execution & Detection

extension GitPlugin {

    /// Run a git command synchronously in the given repo. Used for stage/unstage/discard.
    @discardableResult
    nonisolated static func runGitCommand(repoRoot: String, args: [String]) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot] + args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        return task.runAndWait(seconds: 10)
    }

    // MARK: - Detection Helpers

    nonisolated static func detectChangedFiles(repoRoot: String) -> [GitChangedFile] {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "--no-optional-locks", "status", "--porcelain=v1"]
        task.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe

        // Read on a separate thread before waiting to prevent deadlock when output > 64KB.
        nonisolated(unsafe) var data = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        guard task.runAndWait(seconds: 15) else { return [] }
        readGroup.wait()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let str = String(line)
            guard str.count >= 3 else { return nil }
            let col1 = str[str.startIndex]  // index status
            let col2 = str[str.index(after: str.startIndex)]  // work-tree status
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

    nonisolated static func detectAheadBehind(repoRoot: String) -> (ahead: Int, behind: Int) {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        nonisolated(unsafe) var data = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        guard task.runAndWait(seconds: 15) else { return (0, 0) }
        readGroup.wait()
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
        nonisolated(unsafe) var data = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        guard task.runAndWait(seconds: 15) else { return nil }
        readGroup.wait()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty
        else {
            return nil
        }
        return output
    }

    struct GitRemote: Equatable {
        let name: String
        let url: String

        /// Convert SSH/git URLs to HTTPS browser URLs.
        var webURL: URL? {
            var cleaned = url
            // git@github.com:user/repo.git → https://github.com/user/repo
            if cleaned.hasPrefix("git@") {
                cleaned = cleaned.replacingOccurrences(of: "git@", with: "https://")
                if let colonIdx = cleaned.firstIndex(of: ":"),
                    cleaned[cleaned.startIndex..<colonIdx].contains(".")
                {
                    cleaned =
                        cleaned[cleaned.startIndex..<colonIdx] + "/"
                        + cleaned[cleaned.index(after: colonIdx)...]
                }
            }
            // ssh://git@host/path → https://host/path
            if cleaned.hasPrefix("ssh://") {
                cleaned = cleaned.replacingOccurrences(of: "ssh://", with: "https://")
                if let atIdx = cleaned.firstIndex(of: "@") {
                    cleaned = "https://" + cleaned[cleaned.index(after: atIdx)...]
                }
            }
            // Strip .git suffix
            if cleaned.hasSuffix(".git") {
                cleaned = String(cleaned.dropLast(4))
            }
            guard let url = URL(string: cleaned),
                url.scheme == "https" || url.scheme == "http"
            else { return nil }
            return url
        }
    }

    nonisolated static func detectRemotes(repoRoot: String) -> [GitRemote] {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repoRoot, "remote", "-v"]
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        nonisolated(unsafe) var data = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        guard task.runAndWait(seconds: 15) else { return [] }
        readGroup.wait()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        // git remote -v outputs: origin\thttps://... (fetch)\norigin\thttps://... (push)
        // Deduplicate by name, prefer fetch URL
        var seen: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let rest = String(parts[1])
            // Extract URL (before the (fetch)/(push) suffix)
            let url = rest.split(separator: " ").first.map(String.init) ?? rest
            if seen[name] == nil || rest.contains("(fetch)") {
                seen[name] = url
            }
        }
        return seen.sorted(by: { $0.key < $1.key }).map { GitRemote(name: $0.key, url: $0.value) }
    }

    // MARK: - Refresh & Watcher

    internal func refreshGitStatus(cwd: String, repoRoot: String?) {
        guard let root = repoRoot else {
            let hadData = !cachedFiles.isEmpty || cachedLastCommit != nil || cachedBranch != nil
            let hadBranch = cachedBranch != nil
            cachedBranch = nil
            cachedRepoRoot = nil
            cachedFiles = []
            cachedAheadCount = 0
            cachedBehindCount = 0
            cachedLastCommit = nil
            cachedRemotes = []
            lastRefreshedPath = cwd
            gitDirWatcher?.stop()
            gitDirWatcher = nil
            workTreeWatcher?.stop()
            workTreeWatcher = nil
            watchedRepoRoot = nil
            // Watch CWD so we detect `git init`
            setupCwdWatcher(cwd: cwd)
            if hadBranch {
                onBranchChanged?(nil, nil)
            }
            if hadData {
                onRequestCycleRerun?()
            }
            return
        }
        // Verify .git still exists — repo may have been de-initialized
        let gitDir = (root as NSString).appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: gitDir) {
            refreshGitStatus(cwd: cwd, repoRoot: nil)
            return
        }
        cwdWatcher?.stop()
        cwdWatcher = nil
        lastRefreshedPath = cwd
        setupGitWatcher(repoRoot: root)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            nonisolated(unsafe) var files: [GitChangedFile] = []
            nonisolated(unsafe) var aheadCount = 0
            nonisolated(unsafe) var behindCount = 0
            nonisolated(unsafe) var lastCommit: String?
            nonisolated(unsafe) var remotes: [GitRemote] = []
            // Read branch directly from .git/HEAD — works without git installed.
            let (branch, _) = StatusBarView.detectGitInfo(in: root)
            debugLog("[Git] refreshGitStatus: root=\(root) branch=\(branch ?? "nil")")

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                files = Self.detectChangedFiles(repoRoot: root)
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
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                remotes = Self.detectRemotes(repoRoot: root)
                group.leave()
            }

            group.wait()
            DispatchQueue.main.async {
                guard let self else { return }
                let branchChanged = branch != self.cachedBranch
                let changed =
                    branchChanged
                    || self.cachedFiles.map(\.path) != files.map(\.path)
                    || self.cachedAheadCount != aheadCount
                    || self.cachedBehindCount != behindCount
                    || self.cachedLastCommit != lastCommit
                    || self.cachedRemotes != remotes
                self.cachedBranch = branch
                self.cachedRepoRoot = root
                self.cachedFiles = files
                self.cachedAheadCount = aheadCount
                self.cachedBehindCount = behindCount
                self.cachedLastCommit = lastCommit
                self.cachedRemotes = remotes
                if branchChanged {
                    debugLog("[Git] branch changed: \(self.cachedBranch ?? "nil") -> \(branch ?? "nil") root=\(root)")
                    self.onBranchChanged?(branch, root)
                }
                if changed {
                    self.onRequestCycleRerun?()
                }
            }
        }
    }

    /// Watch CWD for `.git` appearing (e.g. after `git init`).
    private func setupCwdWatcher(cwd: String) {
        cwdWatcher?.stop()
        cwdWatcher = FileSystemWatcher(path: cwd) { [weak self] in
            guard let self else { return }
            let gitDir = (cwd as NSString).appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitDir) else { return }
            // .git appeared — trigger a full cycle rerun so buildGitContext picks it up
            self.cwdWatcher?.stop()
            self.cwdWatcher = nil
            self.onRequestCycleRerun?()
        }
        cwdWatcher?.start()
    }

    internal func setupGitWatcher(repoRoot: String) {
        guard watchedRepoRoot != repoRoot else { return }
        watchedRepoRoot = repoRoot
        gitDirWatcher?.stop()
        workTreeWatcher?.stop()

        let debouncedRefresh: (TimeInterval) -> Void = { [weak self] delay in
            guard let self else { return }
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.refreshGitStatus(cwd: self.lastRefreshedPath ?? repoRoot, repoRoot: repoRoot)
            }
            self.debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // Watch .git/ but filter to only the files that indicate meaningful state changes:
        // HEAD (branch switch), index (stage/unstage), packed-refs (remote tracking).
        // This avoids thrashing on objects/, logs/, and other high-frequency writes.
        let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir) {
            gitDirWatcher = FileSystemWatcher(
                path: gitDir,
                filter: { path in
                    let name = (path as NSString).lastPathComponent
                    return name == "HEAD" || name == "index" || name == "packed-refs"
                        || name == "MERGE_HEAD" || name == "CHERRY_PICK_HEAD"
                },
                onChange: { debouncedRefresh(0.15) }
            )
            gitDirWatcher?.start()
        }

        // Watch the working tree for file creates/modifies/deletes so the changed-file list
        // stays live even when the user hasn't staged anything yet.
        // FSEvents is recursive, so this covers all subdirectories.
        // Skip .git/ paths to avoid double-firing with gitDirWatcher.
        workTreeWatcher = FileSystemWatcher(
            path: repoRoot,
            filter: { path in
                // Ignore anything inside .git/
                !path.contains("/.git/") && !path.hasSuffix("/.git")
            },
            onChange: { debouncedRefresh(0.5) }
        )
        workTreeWatcher?.start()
    }
}
