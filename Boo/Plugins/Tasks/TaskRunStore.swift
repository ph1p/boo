import Combine
import Foundation

/// The last run of a task in one project folder.
struct TaskRun: Codable, Equatable, Sendable {
    var root: String
    var command: String
    var name: String
    var startedAt: Date
    /// nil while running, or when the shell reported none.
    var exitCode: Int32?
    var duration: TimeInterval?

    var key: String { TaskRunStore.key(root: root, command: command) }
}

/// Starts project tasks in new terminal tabs and remembers how each run
/// ended, matched through the app-wide stream of finished commands.
/// Recent runs are kept in `~/.boo/task-runs.json`.
@MainActor
final class TaskRunStore: ObservableObject {
    static let shared = TaskRunStore(
        file: URL(fileURLWithPath: (BooPaths.configDir as NSString).appendingPathComponent("task-runs.json")),
        commands: CommandLog.shared.finished.eraseToAnyPublisher())

    static let limit = 100

    /// Most recent first.
    @Published private(set) var runs: [TaskRun] = []
    /// Runs started here that have not finished yet (in this app session).
    @Published private(set) var running: Set<String> = []

    private let file: URL?
    private var subscription: AnyCancellable?

    init(file: URL?, commands: AnyPublisher<FinishedCommand, Never>) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([TaskRun].self, from: data)
        {
            runs = saved
        }
        subscription = commands.sink { [weak self] command in
            MainActor.assumeIsolated { self?.finished(command) }
        }
    }

    nonisolated static func key(root: String, command: String) -> String {
        ProjectTaskScanner.standardized(root) + "\u{0}" + command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lastRun(of task: ProjectTask, in root: String) -> TaskRun? {
        let key = Self.key(root: root, command: task.command)
        return runs.first { $0.key == key }
    }

    func isRunning(_ task: ProjectTask, in root: String) -> Bool {
        running.contains(Self.key(root: root, command: task.command))
    }

    /// Recently run tasks first, most recent at the top; the rest keep their order.
    func ordered(_ group: ProjectTaskGroup) -> [ProjectTask] {
        let order = Dictionary(
            runs.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = group.tasks.compactMap { task in
            order[Self.key(root: group.root, command: task.command)].map { (task, $0) }
        }
        let recentIDs = Set(recent.map(\.0.id))
        return recent.sorted { $0.1 < $1.1 }.map(\.0) + group.tasks.filter { !recentIDs.contains($0.id) }
    }

    /// Records the start and returns the tab to open for it.
    func start(_ task: ProjectTask, in root: String, now: Date = Date()) -> TabPayload {
        let run = TaskRun(
            root: ProjectTaskScanner.standardized(root), command: task.command, name: task.name, startedAt: now)
        runs.removeAll { $0.key == run.key }
        runs.insert(run, at: 0)
        if runs.count > Self.limit { runs.removeLast(runs.count - Self.limit) }
        running.insert(run.key)
        save()
        return .terminalWithCommand(workingDirectory: root, command: task.command)
    }

    /// A finished command that matches a remembered run updates it, so a task
    /// typed by hand in the same folder counts too.
    func finished(_ command: FinishedCommand) {
        guard command.host == nil else { return }
        let key = Self.key(root: command.cwd, command: command.command)
        guard let index = runs.firstIndex(where: { $0.key == key }) else { return }
        runs[index].startedAt = command.startedAt
        runs[index].exitCode = command.exitCode
        runs[index].duration = command.duration
        running.remove(key)
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(runs) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
