import Foundation

/// Containers sharing a `com.docker.compose.project` label.
struct ComposeProject: Identifiable, Equatable {
    /// Project name; nil for a pinned folder with no containers yet, where
    /// compose derives the name itself.
    var name: String?
    /// `com.docker.compose.project.working_dir`.
    var workingDir: String?
    /// `com.docker.compose.project.config_files`.
    var configFiles: [String] = []
    var containers: [DockerService.Container] = []
    /// The active workspace's folder is this project's directory.
    var isPinned = false

    var id: String { name ?? "dir:\(workingDir ?? "")" }

    var displayName: String {
        name ?? workingDir.map { ($0 as NSString).lastPathComponent } ?? "compose"
    }

    var runningCount: Int { containers.filter { $0.state == .running }.count }

    enum Action: String, CaseIterable {
        case up, down, restart, stop

        var arguments: [String] {
            switch self {
            case .up: return ["up", "-d"]
            case .down: return ["down"]
            case .restart: return ["restart"]
            case .stop: return ["stop"]
            }
        }
    }

    /// `docker` arguments for `action`. Config files that still exist are
    /// passed so `up` works from anywhere; `down`/`stop`/`restart` only need -p.
    func arguments(_ action: Action, fileExists: (String) -> Bool = FileManager.default.fileExists) -> [String] {
        var args = ["compose"]
        if let name { args += ["-p", name] }
        for file in configFiles where fileExists(file) { args += ["-f", file] }
        if let workingDir, name == nil || action == .up { args += ["--project-directory", workingDir] }
        return args + action.arguments
    }

    /// Shell line for running `docker compose … <rest>` in a terminal.
    func shellCommand(_ rest: String) -> String {
        var parts = ["docker", "compose"]
        if let name { parts += ["-p", shellEscape(name)] }
        if name == nil, let workingDir { parts += ["--project-directory", shellEscape(workingDir)] }
        return (parts + [rest]).joined(separator: " ")
    }
}

enum ComposeGrouping {
    static let projectLabel = "com.docker.compose.project"
    static let workingDirLabel = "com.docker.compose.project.working_dir"
    static let configFilesLabel = "com.docker.compose.project.config_files"
    static let serviceLabel = "com.docker.compose.service"

    static let composeFileNames = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
    ]

    /// Whether `folder` holds a compose file.
    static func hasComposeFile(in folder: String, fileExists: (String) -> Bool = FileManager.default.fileExists) -> Bool
    {
        composeFileNames.contains { fileExists((folder as NSString).appendingPathComponent($0)) }
    }

    /// Projects (pinned first, then by name) and the containers outside any
    /// project. `pinnedFolder` is the workspace folder when it holds a
    /// compose file: the project started from there is pinned, or an empty
    /// placeholder stands in so it can be brought up.
    static func group(
        _ containers: [DockerService.Container], pinnedFolder: String?
    ) -> (projects: [ComposeProject], loose: [DockerService.Container]) {
        var projects: [String: ComposeProject] = [:]
        var loose: [DockerService.Container] = []
        for container in containers {
            guard let name = container.composeProject else {
                loose.append(container)
                continue
            }
            var project = projects[name] ?? ComposeProject(name: name)
            if project.workingDir == nil { project.workingDir = container.composeWorkingDir }
            if project.configFiles.isEmpty { project.configFiles = container.composeConfigFiles }
            project.containers.append(container)
            projects[name] = project
        }
        var result = Array(projects.values)
        if let pinnedFolder {
            let folder = standardized(pinnedFolder)
            if let index = result.firstIndex(where: { $0.workingDir.map(standardized) == folder }) {
                result[index].isPinned = true
            } else {
                result.append(ComposeProject(name: nil, workingDir: pinnedFolder, isPinned: true))
            }
        }
        for i in result.indices {
            result[i].containers.sort {
                ($0.composeService ?? $0.name).localizedStandardCompare($1.composeService ?? $1.name)
                    == .orderedAscending
            }
        }
        result.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return (result, loose)
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}
