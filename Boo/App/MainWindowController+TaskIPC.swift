import Foundation

/// Socket commands on an agent task, addressed by the `tab_id` its agent runs
/// in: `task_status`, `task_diff`, `merge_task {cleanup?}`, `discard_task`.
/// `WindowManager` routes them to the window holding the tab.
extension MainWindowController {
    static let taskCommands: Set<String> = ["task_status", "task_diff", "merge_task", "discard_task"]

    /// Largest diff text `task_diff` returns; the file list is always complete.
    nonisolated static let taskDiffLimit = 100_000

    func handleTaskCommand(
        cmd: String, workspace: Workspace, tabID: UUID, json: [String: Any],
        reply: @escaping ([String: Any]) -> Void
    ) {
        // A task opened beside its caller shares the caller's workspace, so its
        // worktree is the tab's directory, not the workspace folder.
        let tabDir = AgentInbox.locateInWindows(tabID).map { $0.pane.tabs[$0.tabIndex].workingDirectory }
        let folders = [tabDir, workspace.folderPath].compactMap { $0 }
        let workspaceID = workspace.id
        let ids: [String: Any] = ["tab_id": tabID.uuidString, "workspace_id": workspaceID.uuidString]
        let statOnly = json["stat_only"] as? Bool ?? false
        let cleanup = json["cleanup"] as? Bool ?? true
        // The state the user approved on the card (set by the gate, never by the caller).
        let approved = AgentWorktree.decodeSnapshot(json)
        let send: ([String: Any]) -> Void = { reply($0.merging(ids) { current, _ in current }) }
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.runTaskCommand(cmd, folders: folders, approved: approved)
            }.value
            switch outcome {
            case .notTask:
                let path = (folders[0] as NSString).abbreviatingWithTildeInPath
                send(["ok": false, "error": "\(path) is not an agent task worktree"])
            case .failed(let message):
                send(["ok": false, "error": message])
            case .status(let check, let info):
                send(Self.serialize(check, info))
            case .blocked(let check, let info):
                send([
                    "ok": false, "error": Self.blockerMessage(check, info) ?? "", "blocker": check.blocker ?? NSNull()
                ])
            case .diff(let changes):
                send(Self.serialize(changes, statOnly: statOnly))
            case .merged(let check, let info):
                var response: [String: Any] = [
                    "ok": true, "merged": check.status.ahead, "target": check.status.target ?? NSNull()
                ]
                guard cleanup, let self else { return send(response) }
                self.closeAndRemoveAgentTask(
                    workspaceID: workspaceID, info: info, tabID: tabID, mode: .afterMerge
                ) { result in
                    if case .success(let kept?) = result { response["kept"] = kept }
                    send(response)
                }
            case .discard(let info):
                guard let self else { return send(["ok": false, "error": "window closed"]) }
                self.closeAndRemoveAgentTask(
                    workspaceID: workspaceID, info: info, tabID: tabID, mode: .discard(approved)
                ) { result in
                    switch result {
                    case .success(let restore):
                        send(["ok": true, "restore": restore ?? NSNull()])
                    case .failure(let error):
                        send(["ok": false, "error": error.localizedDescription])
                    }
                }
            }
        }
    }

    private enum TaskOutcome {
        case notTask
        case failed(String)
        case status(AgentWorktree.MergeCheck, AgentWorktree.Info)
        case blocked(AgentWorktree.MergeCheck, AgentWorktree.Info)
        case diff(AgentReview.Changes)
        case merged(AgentWorktree.MergeCheck, AgentWorktree.Info)
        case discard(AgentWorktree.Info)
    }

    /// The git side of a task command; blocks. `approved` pins merge and
    /// discard to the state the user saw on the approval card.
    nonisolated private static func runTaskCommand(
        _ cmd: String, folders: [String], approved: AgentWorktree.Snapshot?
    ) -> TaskOutcome {
        guard let info = folders.lazy.compactMap(AgentWorktree.info(for:)).first else { return .notTask }
        switch cmd {
        case "task_status":
            return .status(AgentWorktree.mergeCheck(of: info), info)
        case "task_diff":
            do {
                return .diff(try AgentReview.changes(in: info.path))
            } catch {
                return .failed(error.localizedDescription)
            }
        case "merge_task":
            let check = AgentWorktree.mergeCheck(of: info)
            if check.blocker != nil { return .blocked(check, info) }
            do {
                try AgentWorktree.merge(info, approvedHead: approved?.head)
                return .merged(check, info)
            } catch {
                return .failed(error.localizedDescription)
            }
        default:  // discard_task
            // Checked before the agent's tab closes, and again before deleting.
            if let approved,
                let change = AgentWorktree.changes(from: approved, to: AgentWorktree.snapshot(of: info), in: info)
            {
                return .failed(
                    "The task changed since the user approved discarding it: \(change). Nothing was deleted; ask again."
                )
            }
            return .discard(info)
        }
    }

    /// What to do about a task that cannot merge, nil when it can.
    nonisolated static func blockerMessage(_ check: AgentWorktree.MergeCheck, _ info: AgentWorktree.Info) -> String? {
        let branch = info.branch ?? "The worktree"
        let target = check.status.target ?? "the target"
        switch check.blocker {
        case "no_target":
            return "The main checkout is not on a branch, so there is nothing to merge into."
        case "dirty":
            return "\(branch) has uncommitted changes. Ask its agent to commit them."
        case "target_dirty":
            return
                "\((info.mainRoot as NSString).abbreviatingWithTildeInPath) has uncommitted changes. Ask the user to commit or stash them; never stash for them."
        case "conflicts":
            let files = (check.conflicts ?? []).joined(separator: ", ")
            return "\(branch) conflicts with \(target) in \(files). Ask its agent to rebase onto \(target)."
        case "nothing_to_merge":
            return "\(branch) has no commits that \(target) lacks."
        default:
            return nil
        }
    }

    nonisolated private static func serialize(
        _ check: AgentWorktree.MergeCheck, _ info: AgentWorktree.Info
    ) -> [String: Any] {
        [
            "ok": true, "path": info.path, "branch": info.branch ?? NSNull(),
            "target": check.status.target ?? NSNull(), "ahead": check.status.ahead, "behind": check.behind,
            "dirty": check.status.isDirty, "target_dirty": check.targetDirty,
            "conflicts": check.conflicts ?? NSNull(), "mergeable": check.blocker == nil,
            "blocker": check.blocker ?? NSNull(), "hint": blockerMessage(check, info) ?? NSNull()
        ]
    }

    nonisolated private static func serialize(_ changes: AgentReview.Changes, statOnly: Bool) -> [String: Any] {
        let files: [[String: Any]] = changes.files.map { file in
            var entry: [String: Any] = [
                "path": file.path, "status": String(describing: file.status),
                "additions": file.additions, "deletions": file.deletions
            ]
            if let old = file.oldPath { entry["old_path"] = old }
            if file.isBinary { entry["binary"] = true }
            return entry
        }
        var out: [String: Any] = [
            "ok": true, "base": changes.base, "branch": changes.branch ?? NSNull(), "files": files,
            "additions": changes.files.reduce(0) { $0 + $1.additions },
            "deletions": changes.files.reduce(0) { $0 + $1.deletions }
        ]
        if !statOnly {
            let text = unifiedText(changes.files)
            out["diff"] = String(text.prefix(taskDiffLimit))
            out["truncated"] = text.count > taskDiffLimit
        }
        return out
    }

    /// The parsed diff back as text: one `--- path` block per file, hunks as git prints them.
    nonisolated static func unifiedText(_ files: [AgentReview.FileDiff]) -> String {
        var out = ""
        for file in files {
            out += "--- \(file.oldPath.map { "\($0) → " } ?? "")\(file.path) (\(file.status))\n"
            if file.isBinary { out += "Binary file\n" }
            for hunk in file.hunks {
                out += hunk.header + "\n"
                for line in hunk.lines {
                    switch line.kind {
                    case .context: out += " "
                    case .added: out += "+"
                    case .removed: out += "-"
                    }
                    out += line.text + "\n"
                }
            }
        }
        return out
    }
}
