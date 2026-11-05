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

/// Estimated agent spend against `agentBudgetPerTask` / `agentBudgetPerDay`:
/// per task from the transcripts of the agents in the inbox, per day from
/// every Claude Code session (`AgentCostLedger`). Warn only: amber at 80 %,
/// red plus one notification when a budget is passed. Idle while
/// `agentCostTracking` is off.
@MainActor
final class AgentBudget {
    static let shared = AgentBudget()

    /// Estimated cost of each agent's session, by tab.
    private(set) var taskCosts: [UUID: Double] = [:]
    /// Today's estimated cost of every Claude Code session.
    private(set) var todayTotal = 0.0
    private var day = Calendar.current.startOfDay(for: Date())
    private var crossings = BudgetCrossings()
    private var observers: [NSObjectProtocol] = []
    private let refreshDebouncer = Debouncer(delay: 3)
    private var refreshing = false

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
        guard AppSettings.shared.agentCostTracking else {
            stop()
            return
        }
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
            let costs = sessions.compactMap { entry -> (UUID, String, Double)? in
                guard let url = AgentTimeline.transcriptURL(sessionID: entry.sessionID),
                    let timeline = AgentTimelineStore.shared.load(url)
                else { return nil }
                return (entry.tabID, entry.sessionID, timeline.cost)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let budget = AgentBudget.shared
                    budget.applyTasks(costs, dayStart: dayStart)
                    AgentCostLedger.shared.refresh {
                        let budget = AgentBudget.shared
                        budget.refreshing = false
                        budget.applyDay(AgentCostLedger.shared.total(since: dayStart))
                    }
                }
            }
        }
    }

    /// Tracking was turned off: forget every cost.
    private func stop() {
        AgentCostLedger.shared.unload()
        guard !taskCosts.isEmpty || todayTotal > 0 else { return }
        taskCosts = [:]
        todayTotal = 0
        crossings.reset()
        NotificationCenter.default.post(name: .agentBudgetChanged, object: self)
    }

    private func applyTasks(_ costs: [(tabID: UUID, sessionID: String, total: Double)], dayStart: Date) {
        if dayStart != day {
            day = dayStart
            todayTotal = 0
            crossings.reset()
        }
        let settings = AppSettings.shared
        taskCosts = [:]
        for entry in costs {
            taskCosts[entry.tabID] = entry.total
            if crossings.update("task:" + entry.sessionID, cost: entry.total, budget: settings.agentBudgetPerTask),
                let budget = settings.agentBudgetPerTask
            {
                notifyTask(entry.tabID, cost: entry.total, budget: budget)
            }
        }
        NotificationCenter.default.post(name: .agentBudgetChanged, object: self)
    }

    private func applyDay(_ total: Double) {
        todayTotal = total
        let settings = AppSettings.shared
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

    nonisolated static func format(_ cost: Double) -> String {
        String(format: cost < 10 ? "$%.2f" : "$%.0f", cost)
    }
}
