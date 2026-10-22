import Foundation

extension Notification.Name {
    static let agentBudgetChanged = Notification.Name("BooAgentBudgetChanged")
}

/// How close an estimated cost is to its budget.
enum BudgetLevel: Int, Comparable {
    case ok
    /// 80 % or more.
    case warning
    /// At or past the budget.
    case over

    static func < (a: BudgetLevel, b: BudgetLevel) -> Bool { a.rawValue < b.rawValue }

    static func of(cost: Double, budget: Double?) -> BudgetLevel {
        guard let budget, budget > 0 else { return .ok }
        if cost >= budget { return .over }
        return cost >= budget * 0.8 ? .warning : .ok
    }
}

/// Last level per budget key, so each crossing notifies once.
struct BudgetCrossings {
    private(set) var levels: [String: BudgetLevel] = [:]

    /// Records `key`'s new level; true when it just went over.
    mutating func update(_ key: String, cost: Double, budget: Double?) -> Bool {
        let level = BudgetLevel.of(cost: cost, budget: budget)
        let previous = levels[key] ?? .ok
        levels[key] = level
        return level == .over && previous < .over
    }

    mutating func reset() { levels = [:] }
}

/// Estimated agent spend against `agentBudgetPerTask` / `agentBudgetPerDay`,
/// from the transcripts of the agents in the inbox. Warn only: amber at 80 %,
/// red plus one notification when a budget is passed.
@MainActor
final class AgentBudget {
    static let shared = AgentBudget()

    /// Estimated cost of each agent's session, by tab.
    private(set) var taskCosts: [UUID: Double] = [:]
    /// Today's estimated cost of every session seen today, by session ID
    /// (kept after the agent's tab closes).
    private var todayBySession: [String: Double] = [:]
    private var day = Calendar.current.startOfDay(for: Date())
    private var crossings = BudgetCrossings()
    private var observers: [NSObjectProtocol] = []
    private let refreshDebouncer = Debouncer(delay: 3)
    private var refreshing = false

    var todayTotal: Double { todayBySession.values.reduce(0, +) }

    var dayLevel: BudgetLevel { BudgetLevel.of(cost: todayTotal, budget: AppSettings.shared.agentBudgetPerDay) }

    func taskLevel(_ tabID: UUID) -> BudgetLevel {
        BudgetLevel.of(cost: taskCosts[tabID] ?? 0, budget: AppSettings.shared.agentBudgetPerTask)
    }

    /// The worst of the day and every task.
    var level: BudgetLevel {
        taskCosts.keys.map(taskLevel).reduce(dayLevel, max)
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(forName: .agentInboxChanged, object: nil, queue: .main) {
                _ in MainActor.assumeIsolated { AgentBudget.shared.scheduleRefresh() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) {
                note in
                let topic = note.userInfo?["topic"] as? String
                guard topic == nil || topic == SettingsTopic.agents.rawValue else { return }
                MainActor.assumeIsolated { AgentBudget.shared.scheduleRefresh() }
            })
    }

    /// Hook events arrive per tool call; a 3 s debounce keeps transcript reads rare.
    private func scheduleRefresh() {
        refreshDebouncer.schedule { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard !refreshing else {
            scheduleRefresh()
            return
        }
        let sessions = AgentInbox.shared.items.values.compactMap { item in
            item.sessionID.map { (tabID: item.tabID, sessionID: $0) }
        }
        let dayStart = Calendar.current.startOfDay(for: Date())
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let costs = sessions.compactMap { entry -> (UUID, String, Double, Double)? in
                guard let url = AgentTimeline.transcriptURL(sessionID: entry.sessionID),
                    let timeline = AgentTimelineStore.shared.load(url)
                else { return nil }
                return (entry.tabID, entry.sessionID, timeline.cost, Self.cost(of: timeline, since: dayStart))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let budget = AgentBudget.shared
                    budget.refreshing = false
                    budget.apply(costs, dayStart: dayStart)
                }
            }
        }
    }

    private func apply(_ costs: [(tabID: UUID, sessionID: String, total: Double, today: Double)], dayStart: Date) {
        if dayStart != day {
            day = dayStart
            todayBySession = [:]
            crossings.reset()
        }
        let settings = AppSettings.shared
        taskCosts = [:]
        for entry in costs {
            taskCosts[entry.tabID] = entry.total
            if entry.today > 0 { todayBySession[entry.sessionID] = entry.today }
            if crossings.update("task:" + entry.sessionID, cost: entry.total, budget: settings.agentBudgetPerTask),
                let budget = settings.agentBudgetPerTask
            {
                notifyTask(entry.tabID, cost: entry.total, budget: budget)
            }
        }
        if crossings.update("day", cost: todayTotal, budget: settings.agentBudgetPerDay),
            let budget = settings.agentBudgetPerDay
        {
            ActivityNotifier.shared.notifyBudget(
                title: "Daily agent budget passed",
                body: "Today ≈ \(Self.format(todayTotal)) of \(Self.format(budget))")
        }
        NotificationCenter.default.post(name: .agentBudgetChanged, object: self)
    }

    private func notifyTask(_ tabID: UUID, cost: Double, budget: Double) {
        let inbox = AgentInbox.shared
        let name = inbox.items[tabID].map { AgentHandoff.label(for: $0) } ?? "Agent"
        let location = inbox.locate(tabID)
        ActivityNotifier.shared.notifyBudget(
            title: "\(name) passed its budget", body: "≈ \(Self.format(cost)) of \(Self.format(budget))",
            workspaceID: location?.workspace.id, paneID: location?.pane.id, tabIndex: location?.tabIndex ?? 0)
    }

    /// What `timeline` cost since `dayStart`: all of it when it started today,
    /// else the turns that started today (subagent cost is not split by turn).
    nonisolated static func cost(of timeline: AgentTimeline, since dayStart: Date) -> Double {
        if let start = timeline.start, start >= dayStart { return timeline.cost }
        return timeline.turns.filter { ($0.start ?? .distantPast) >= dayStart }.reduce(0) { $0 + $1.cost }
    }

    nonisolated static func format(_ cost: Double) -> String {
        String(format: cost < 10 ? "$%.2f" : "$%.0f", cost)
    }
}
