import Cocoa

/// Where tmux commands go: the surface running `tmux -CC`.
@MainActor
protocol TmuxGateway: AnyObject {
    func writeTmuxCommand(_ line: String)
    /// The gateway terminal's size, used as the client size until the panes report theirs.
    var tmuxGridSize: TmuxProtocol.CellSize? { get }
}

/// Shows tmux windows as Boo workspaces.
@MainActor
protocol TmuxHost: AnyObject {
    /// Opens a workspace laid out as `tree`; each leaf runs `programs[leaf]`.
    func tmuxOpenWorkspace(
        window: String, name: String, tree: SplitTree, programs: [UUID: String], focus: Bool
    )
        -> UUID?
    /// Lays the workspace out as `tree`: leaves in `programs` are new panes,
    /// panes missing from `tree` close.
    func tmuxApplyLayout(workspace: UUID, tree: SplitTree, programs: [UUID: String])
    func tmuxRenameWorkspace(_ workspace: UUID, name: String)
    func tmuxCloseWorkspace(_ workspace: UUID)
    func tmuxShowWorkspace(_ workspace: UUID)
    /// tmux made `pane` its window's active pane.
    func tmuxFocusPane(_ pane: UUID, workspace: UUID)
    /// tmux switched the session to the window `workspace` shows; follow it
    /// only while one of the session's windows is in front.
    func tmuxSelectWorkspace(_ workspace: UUID)
    /// Shows only `pane` (nil: every pane), as tmux zoomed or unzoomed it.
    func tmuxSetZoom(workspace: UUID, pane: UUID?)
    /// A pane's working directory or running command changed in tmux.
    func tmuxPaneChanged(_ pane: UUID, directory: String?, command: String?)
    /// tmux paused (or resumed) the pane's output under flow control.
    func tmuxPanePaused(_ pane: UUID, paused: Bool)
    func tmuxShowError(_ message: String)
    /// Asks which of a large session's windows to open; `choose` gets their
    /// ids, or nil to open every one.
    func tmuxChooseWindows(
        _ windows: [TmuxProtocol.WindowInfo], session: String, choose: @escaping (Set<String>?) -> Void)
    func tmuxCopyToClipboard(_ text: String)
}

/// Drives one tmux control-mode connection (`tmux -CC`). Each tmux window
/// becomes a workspace and each tmux pane a Boo pane running a bridge process
/// (`Boo --tmux-bridge`) that shows the pane's output and forwards its keys.
@MainActor
final class TmuxControlClient {
    private final class PaneLink {
        enum Phase {
            /// Waiting for `capture-pane`; output so far is already in the capture.
            case capturing
            /// Captured; waiting for the cursor. Output goes to `held` to follow the capture.
            case awaitingCursor
            case live
        }

        let id: UUID
        let tmuxID: String
        let window: String
        let token: String
        var phase = Phase.capturing
        var screen: [[UInt8]] = []
        var held: [UInt8] = []
        var names = TmuxProtocol.NameSequenceFilter()
        var connected = false
        /// Output waiting for the bridge to connect.
        var pending: [UInt8] = []
        /// Closing on purpose; its bridge disconnect is expected.
        var closing = false
        var tmuxSize: TmuxProtocol.CellSize?
        var bridgeSize: TmuxProtocol.CellSize?
        var requestedSize: TmuxProtocol.CellSize?
        /// tmux stopped sending its output (flow control).
        var paused = false

        init(id: UUID, tmuxID: String, window: String, token: String) {
            self.id = id
            self.tmuxID = tmuxID
            self.window = window
            self.token = token
        }
    }

    private struct WindowLink {
        let workspace: UUID
        var tree: SplitTree
        var name: String
        /// The window's active pane as Boo last told or heard from tmux.
        var activePane = ""
        var zoomed = false
    }

    /// A sent command waiting for its reply.
    private struct Pending {
        let command: String
        let reply: ((Reply) -> Void)?
        /// An error reply is expected now and then (a pane already gone) and
        /// is not shown.
        let quiet: Bool
    }

    private struct Block {
        let number: String
        let pending: Pending?
        var lines: [[UInt8]] = []
    }

    struct Reply {
        let lines: [[UInt8]]
        let isError: Bool
        var text: [String] { lines.map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Settings read when they matter; tests pin them.
    struct Options {
        var historyLines = 1000
        var pauseAfterSeconds = 0
        var autoUnpause = false
        var externalWindowsInBackground = true
        var attachWindowLimit = 10
        var mirrorPasteBuffer = false

        static var current: Options {
            let settings = AppSettings.shared
            return Options(
                historyLines: max(0, settings.tmuxHistoryLines),
                pauseAfterSeconds: max(0, settings.tmuxPauseAfterSeconds),
                autoUnpause: settings.tmuxAutoUnpause,
                externalWindowsInBackground: settings.tmuxExternalWindowsInBackground,
                attachWindowLimit: max(0, settings.tmuxAttachWindowLimit),
                mirrorPasteBuffer: settings.tmuxMirrorPasteBuffer)
        }
    }

    var options: () -> Options = { .current }

    /// `refresh-client -B` subscriptions feeding each pane's tab.
    static let directorySubscription = "boo-cwd"
    static let commandSubscription = "boo-cmd"

    /// Output held for a bridge that hasn't connected stays under this.
    static let maxPending = 4 << 20
    /// After applying a tmux layout, Boo's resulting pane sizes are not sent
    /// back as `resize-pane` for this long, so rounding can't ping-pong.
    static let layoutSettle: TimeInterval = 0.5

    private static var live: [Weak] = []
    private struct Weak { weak var client: TmuxControlClient? }
    private static var observesTermination = false

    private weak var gateway: TmuxGateway?
    private weak var host: TmuxHost?
    private let bridges: TmuxBridgeServer
    private var started = false
    private var ended = false
    private var held: [String] = []
    /// Sent commands in order; `replyHead` is the next one due a reply.
    private var replies: [Pending] = []
    private var replyHead = 0
    /// Output for connected bridges, sent once per batch of gateway lines.
    private var outgoing: [String: [UInt8]] = [:]
    private var block: Block?
    private var windows: [String: WindowLink] = [:]
    private var panes: [String: PaneLink] = [:]
    private var clientSize: TmuxProtocol.CellSize?
    private var settleUntil = Date.distantPast
    private var sizeSync: DispatchWorkItem?
    /// The window whose panes last changed size; it sets the client size.
    private var sizingWindow: String?
    /// The session's current window, as Boo last told or heard from tmux.
    private var activeWindow: String?
    /// The server's version (`TmuxProtocol.version`), once known.
    private(set) var version: Double?
    /// Windows Boo itself created (new-window, break-pane): they open in front.
    private var ownWindows: Set<String> = []
    private var pendingRenames: [String: DispatchWorkItem] = [:]
    /// Windows left closed on attach, by id, with their names.
    private var unopened: [String: String] = [:]
    /// The server's sessions, refreshed when tmux says they changed.
    private(set) var sessions: [TmuxSessions.Session] = []

    init(gateway: TmuxGateway, host: TmuxHost, bridges: TmuxBridgeServer = .shared) {
        self.gateway = gateway
        self.host = host
        self.bridges = bridges
        Self.live.removeAll { $0.client == nil }
        Self.live.append(Weak(client: self))
        guard !Self.observesTermination else { return }
        Self.observesTermination = true
        // Quitting closes every pane; that must not kill the tmux panes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TmuxControlClient.rememberAttachedSessions()
                for client in TmuxControlClient.live.compactMap(\.client) { client.ended = true }
            }
        }
    }

    /// The client showing `workspace`, if it is a tmux window.
    static func owning(workspace: UUID) -> TmuxControlClient? {
        live.lazy.compactMap(\.client).first { $0.windows.values.contains { $0.workspace == workspace } }
    }

    /// The client showing `pane`, if it is a tmux pane.
    static func owning(pane: UUID) -> TmuxControlClient? {
        live.lazy.compactMap(\.client).first { $0.owns(pane: pane) }
    }

    /// Every live client, oldest first.
    static var all: [TmuxControlClient] { live.compactMap(\.client) }

    static func client(id: UUID) -> TmuxControlClient? {
        live.lazy.compactMap(\.client).first { $0.id == id }
    }

    /// Names this connection in the workspace bar (`tmux:<id>` group).
    let id = UUID()
    /// The window showing this session's workspaces.
    var hostedBy: TmuxHost? { host }
    /// The ssh host the session runs on, when Boo started it there.
    var remoteHost: String?
    /// The terminal that ran `tmux -CC`, out of sight while control mode lasts.
    var parked: TmuxParkedGateway?

    /// "session" or "host: session", for the session's chip and menus.
    var label: String {
        // tmux numbers unnamed sessions; a bare "0" says nothing on its own.
        let name = session.map { $0.allSatisfy(\.isNumber) ? "session \($0)" : $0 } ?? "tmux"
        return remoteHost.map { "\($0): \(name)" } ?? name
    }

    /// The attached session's name, once tmux reported it.
    private(set) var session: String?
    private var sessionID: String?
    /// The text after `%exit`, once tmux said it is ending this client.
    private var exitReason: String?
    private var killed = false

    /// The session outlived this connection (detached, or the gateway's
    /// terminal or ssh went away), so attaching again makes sense.
    var canReattach: Bool {
        guard session != nil, !killed else { return false }
        guard let exitReason else { return true }
        return exitReason.hasPrefix("detached") || exitReason == "lost tty"
    }
    /// Called once per run loop turn in which the session or its windows changed.
    var onChange: (() -> Void)?
    private var changePending = false

    /// This session's windows in tmux order, with the workspace showing each.
    var windowList: [(workspace: UUID, name: String)] {
        windows.sorted { Self.order($0.key) < Self.order($1.key) }.map { ($0.value.workspace, $0.value.name) }
    }

    /// Windows not opened on attach (see `tmuxAttachWindowLimit`).
    var unopenedWindows: [(id: String, name: String)] {
        unopened.sorted { Self.order($0.key) < Self.order($1.key) }.map { ($0.key, $0.value) }
    }

    private static func order(_ window: String) -> Int { Int(window.dropFirst()) ?? .max }

    // MARK: - Gateway input

    func receive(_ raw: [UInt8]) {
        receive(lines: [raw])
    }

    /// Handles a batch of gateway lines, then sends the output they produced.
    func receive(lines: [[UInt8]]) {
        for raw in lines { handle(raw) }
        for (token, bytes) in outgoing { bridges.send(token, bytes) }
        outgoing.removeAll(keepingCapacity: true)
    }

    private func handle(_ raw: [UInt8]) {
        if var open = block {
            // Reply bodies (captures run to 1000 lines) only need the end marker found.
            let line = raw.first == UInt8(ascii: "%") ? TmuxProtocol.parse(raw) : .other
            switch line {
            case .end(let n) where n == open.number:
                block = nil
                open.pending?.reply?(Reply(lines: open.lines, isError: false))
            case .error(let n) where n == open.number:
                block = nil
                let reply = Reply(lines: open.lines, isError: true)
                if let pending = open.pending {
                    if let handler = pending.reply {
                        handler(reply)
                    } else if !pending.quiet {
                        report(reply, of: pending.command)
                    }
                }
            default:
                open.lines.append(raw)
                block = open
            }
            return
        }
        switch TmuxProtocol.parse(raw) {
        case .begin(let number, let fromClient):
            block = Block(number: number, pending: fromClient ? nextReply() : nil)
        case .output(let pane, let data):
            output(data, to: pane)
        case .layoutChange(let window, let layout, let zoomed):
            if windows[window] != nil { apply(layout: layout, window: window, zoomed: zoomed) }
        case .windowAdd(let window):
            guard started else { return }
            lookUp(window) { [weak self] info in
                guard let self else { return }
                let own = self.ownWindows.remove(info.id) != nil
                self.open(info, focus: own || !self.options().externalWindowsInBackground)
            }
        case .windowClose(let window):
            if unopened.removeValue(forKey: window) != nil { changed() }
            close(window: window)
        case .windowRenamed(let window, let name):
            if unopened[window] != nil {
                unopened[window] = name
                changed()
            }
            guard let workspace = windows[window]?.workspace else { return }
            windows[window]?.name = name
            host?.tmuxRenameWorkspace(workspace, name: name)
            changed()
        case .windowPaneChanged(let window, let paneID):
            guard let link = windows[window], link.activePane != paneID else { return }
            windows[window]?.activePane = paneID
            if let pane = panes[paneID], pane.window == window, !pane.closing {
                host?.tmuxFocusPane(pane.id, workspace: link.workspace)
            }
        case .sessionWindowChanged(let session, let window):
            guard session == sessionID, activeWindow != window else { return }
            activeWindow = window
            if let link = windows[window] { host?.tmuxSelectWorkspace(link.workspace) }
        case .sessionsChanged:
            if started { refreshSessions() }
        case .subscriptionChanged(let name, let paneID, let value):
            guard let pane = panes[paneID], !pane.closing else { return }
            switch name {
            case Self.directorySubscription:
                host?.tmuxPaneChanged(pane.id, directory: value, command: nil)
            case Self.commandSubscription:
                host?.tmuxPaneChanged(pane.id, directory: nil, command: value)
            default:
                break
            }
        case .pause(let paneID):
            guard let pane = panes[paneID] else { return }
            if options().autoUnpause {
                send(Self.continueCommand(paneID), quiet: true)
            } else {
                pane.paused = true
                host?.tmuxPanePaused(pane.id, paused: true)
            }
        case .resume(let paneID):
            guard let pane = panes[paneID] else { return }
            if pane.paused {
                pane.paused = false
                host?.tmuxPanePaused(pane.id, paused: false)
            }
            // Output sent while paused is gone: redraw from tmux's screen.
            pane.phase = .capturing
            pane.held = []
            capture(pane, history: false)
        case .pasteBufferChanged(let name):
            guard started, options().mirrorPasteBuffer else { return }
            send("show-buffer -b \(LinkResolver.shellQuote(name))", quiet: true) { [weak self] reply in
                guard let self, !reply.isError else { return }
                self.host?.tmuxCopyToClipboard(reply.text.joined(separator: "\n"))
            }
        case .sessionRenamed(let id, let name):
            guard id == sessionID else { return }
            session = name
            changed()
        case .sessionChanged(let id, let name):
            sessionID = id
            if started {
                for window in Array(windows.keys) { close(window: window) }
            }
            unopened.removeAll()
            activeWindow = nil
            session = name
            start()
            changed()
        case .exit:
            exitReason = String(decoding: raw.dropFirst(5), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        case .end, .error, .other:
            break
        }
    }

    /// The gateway left control mode, or its terminal closed.
    func gatewayExited() {
        ended = true
        for window in Array(windows.keys) { close(window: window) }
        for pane in panes.values { bridges.unregister(pane.token) }
        panes.removeAll()
        replies.removeAll()
        replyHead = 0
        Self.live.removeAll { $0.client == nil || $0.client === self }
    }

    /// Asks tmux to detach; the gateway then leaves control mode.
    func detach() {
        guard !ended else { return }
        send("detach-client")
        ended = true
    }

    // MARK: - Boo actions

    func split(pane id: UUID, toward edge: PaneDirection) {
        guard let pane = tmuxID(of: id) else { return }
        send("split-window \(Self.flags(edge)) -t \(pane)")
    }

    /// Boo focused `pane`: make it tmux's active pane, in the current window.
    func focus(pane id: UUID) {
        guard started, !ended, let pane = panes.values.first(where: { $0.id == id && !$0.closing }),
            let link = windows[pane.window]
        else { return }
        select(window: pane.window)
        guard link.activePane != pane.tmuxID else { return }
        windows[pane.window]?.activePane = pane.tmuxID
        send("select-pane -t \(pane.tmuxID)", quiet: true)
    }

    /// Boo showed `workspace`: make its window the session's current one.
    func focus(workspace: UUID) {
        guard started, !ended, let window = window(of: workspace) else { return }
        select(window: window)
    }

    private func select(window: String) {
        guard activeWindow != window else { return }
        activeWindow = window
        send("select-window -t \(window)", quiet: true)
    }

    /// Moves focus the way tmux would (`select-pane -L` and so on); the
    /// pane tmux picks comes back as `%window-pane-changed`.
    func focusPane(from id: UUID, toward direction: PaneDirection) {
        guard let pane = tmuxID(of: id) else { return }
        let flag: String
        switch direction {
        case .left: flag = "-L"
        case .right: flag = "-R"
        case .up: flag = "-U"
        case .down: flag = "-D"
        }
        send("select-pane \(flag) -t \(pane)", quiet: true)
    }

    /// The next (`step` > 0) or previous pane in tmux's order.
    func cyclePane(from id: UUID, by step: Int) {
        guard let pane = panes.values.first(where: { $0.id == id && !$0.closing }) else { return }
        send("select-pane -t \(pane.window).\(step > 0 ? "+" : "-")", quiet: true)
    }

    /// Zooms `pane` to fill its window, or unzooms it (`resize-pane -Z`).
    func toggleZoom(pane id: UUID) {
        guard let pane = tmuxID(of: id) else { return }
        send("resize-pane -Z -t \(pane)")
    }

    /// Renames `workspace`'s window. The workspace editor renames as the
    /// user types, so the command waits for a pause in typing.
    func renameWindow(workspace: UUID, to name: String, after delay: TimeInterval = 0.4) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let window = window(of: workspace) else { return }
        pendingRenames[window]?.cancel()
        pendingRenames[window] = nil
        guard !name.isEmpty else { return }
        let rename = DispatchWorkItem { [weak self] in
            guard let self, !self.ended, self.windows[window] != nil, self.windows[window]?.name != name else { return }
            self.pendingRenames[window] = nil
            self.send("rename-window -t \(window) -- \(LinkResolver.shellQuote(name))")
        }
        guard delay > 0 else { return rename.perform() }
        pendingRenames[window] = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: rename)
    }

    /// Moves `workspace`'s window to match the order of `workspaces` (Boo's
    /// workspace order after a drag; other workspaces are skipped).
    func reorder(_ workspace: UUID, in workspaces: [UUID]) {
        guard let window = window(of: workspace) else { return }
        let order = workspaces.compactMap(self.window(of:))
        guard let command = TmuxProtocol.moveWindow(window, toMatch: order) else { return }
        // `move-window -b` needs tmux 3.2.
        if command.contains(" -b "), (version ?? 0) < TmuxProtocol.controlFeaturesVersion { return }
        send(command)
    }

    func unpause(pane id: UUID) {
        guard let pane = tmuxID(of: id) else { return }
        send(Self.continueCommand(pane), quiet: true)
    }

    private static func continueCommand(_ pane: String) -> String {
        "refresh-client -A \(LinkResolver.shellQuote("\(pane):continue"))"
    }

    /// Opens a window that was left closed on attach.
    func openWindow(_ id: String) {
        guard unopened.removeValue(forKey: id) != nil else { return }
        changed()
        lookUp(id) { [weak self] info in self?.open(info, focus: true) }
    }

    /// Moves this client to another session; tmux answers `%session-changed`.
    func switchSession(to name: String) {
        guard name != session else { return }
        send("switch-client -t \(LinkResolver.shellQuote(name))")
    }

    /// Runs a tmux command typed by the user.
    func run(_ command: String, reply: @escaping (Reply) -> Void) {
        let command = command.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !ended else { return }
        send(command, reply: reply)
    }

    /// Whether `pane` is one of this session's panes.
    func owns(pane id: UUID) -> Bool { tmuxID(of: id) != nil }

    /// Moves `source` next to `target`, which may be in another window;
    /// `full` spans the target window's whole side.
    func join(pane source: UUID, to target: UUID, toward edge: PaneDirection, full: Bool) {
        guard source != target, let from = tmuxID(of: source), let to = tmuxID(of: target) else { return }
        send("join-pane \(Self.flags(edge))\(full ? " -f" : "") -s \(from) -t \(to)")
    }

    func swap(pane a: UUID, with b: UUID) {
        guard a != b, let first = tmuxID(of: a), let second = tmuxID(of: b) else { return }
        send("swap-pane -s \(first) -t \(second)")
    }

    /// Moves `pane` into a new window of its own.
    func breakOut(pane id: UUID) {
        guard let pane = tmuxID(of: id) else { return }
        createWindow("break-pane -P -F '#{window_id}' -s \(pane)")
    }

    private func tmuxID(of id: UUID) -> String? {
        panes.values.first { $0.id == id && !$0.closing }?.tmuxID
    }

    private func window(of workspace: UUID) -> String? {
        windows.first { $0.value.workspace == workspace }?.key
    }

    private static func flags(_ edge: PaneDirection) -> String {
        switch edge {
        case .right: return "-h"
        case .left: return "-h -b"
        case .down: return "-v"
        case .up: return "-v -b"
        }
    }

    func newWindow() {
        createWindow("new-window -P -F '#{window_id}'")
    }

    /// Runs a command printing the window it makes, which then opens in front.
    private func createWindow(_ command: String) {
        send(command) { [weak self] reply in
            guard let self else { return }
            if reply.isError { return self.report(reply, of: command) }
            if let id = reply.text.first, id.hasPrefix("@") { self.ownWindows.insert(id) }
        }
    }

    func renameSession(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        send("rename-session -- \(LinkResolver.shellQuote(name))")
    }

    /// Ends the session and every program in it; the gateway then exits.
    func killSession() {
        guard !ended else { return }
        send("kill-session")
        killed = true
        ended = true
    }

    func show(workspace: UUID) {
        host?.tmuxShowWorkspace(workspace)
    }

    // MARK: - Commands

    private func send(_ command: String, quiet: Bool = false, reply: ((Reply) -> Void)? = nil) {
        replies.append(Pending(command: command, reply: reply, quiet: quiet))
        guard started else { return held.append(command) }
        gateway?.writeTmuxCommand(command)
    }

    /// Shows an error reply tmux sent for `command`.
    private func report(_ reply: Reply, of command: String) {
        let text = reply.text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = command.split(separator: " ").first.map(String.init) ?? command
        host?.tmuxShowError(text.isEmpty ? "tmux \(verb) failed" : "tmux \(verb): \(text)")
    }

    private func nextReply() -> Pending? {
        guard replyHead < replies.count else { return nil }
        let reply = replies[replyHead]
        replyHead += 1
        if replyHead == replies.count {
            replies.removeAll(keepingCapacity: true)
            replyHead = 0
        } else if replyHead >= 64, replyHead * 2 >= replies.count {
            replies.removeFirst(replyHead)
            replyHead = 0
        }
        return reply
    }

    private func start() {
        started = true
        for command in held { gateway?.writeTmuxCommand(command) }
        held.removeAll()
        if let size = gateway?.tmuxGridSize { setClientSize(size) }
        if version == nil {
            send("display -p '#{version}'", quiet: true) { [weak self] reply in
                guard let self else { return }
                let version = reply.isError ? 0 : TmuxProtocol.version(reply.text.first ?? "")
                self.version = version
                if version >= TmuxProtocol.controlFeaturesVersion { self.enableControlFeatures() }
            }
        }
        refreshSessions()
        send("list-windows -F \"\(TmuxProtocol.windowFormat)\"") { [weak self] reply in
            guard let self, !reply.isError else { return }
            let infos = reply.text.compactMap(TmuxProtocol.windowInfo)
            self.activeWindow = infos.first(where: \.active)?.id
            let limit = self.options().attachWindowLimit
            guard limit > 0, infos.count > limit, let host = self.host else {
                return self.openAttached(infos, chosen: nil)
            }
            host.tmuxChooseWindows(infos, session: self.label) { [weak self] chosen in
                self?.openAttached(infos, chosen: chosen)
            }
        }
    }

    /// Pane directory and command subscriptions, and flow control (tmux 3.2+).
    private func enableControlFeatures() {
        for (name, format) in [
            (Self.directorySubscription, "#{pane_current_path}"), (Self.commandSubscription, "#{pane_current_command}")
        ] {
            send("refresh-client -B \(LinkResolver.shellQuote("\(name):%*:\(format)"))", quiet: true)
        }
        let pauseAfter = options().pauseAfterSeconds
        if pauseAfter > 0 { send("refresh-client -f pause-after=\(pauseAfter)", quiet: true) }
    }

    private func refreshSessions() {
        send("list-sessions -F \(LinkResolver.shellQuote(TmuxSessions.listFormat))", quiet: true) { [weak self] reply in
            guard let self, !reply.isError else { return }
            self.sessions = TmuxSessions.parse(reply.text.joined(separator: "\n"))
            self.changed()
        }
    }

    private func openAttached(_ infos: [TmuxProtocol.WindowInfo], chosen: Set<String>?) {
        guard !ended else { return }
        let opening = TmuxProtocol.windowsToOpen(infos, chosen: chosen)
        let ids = Set(opening.map(\.id))
        for info in infos where !ids.contains(info.id) { unopened[info.id] = info.name }
        for info in opening { open(info, focus: info.active) }
        changed()
    }

    /// Asks tmux for `window`'s details.
    private func lookUp(_ window: String, then handle: @escaping (TmuxProtocol.WindowInfo) -> Void) {
        send("display -p -t \(window) \"\(TmuxProtocol.windowFormat)\"", quiet: true) { reply in
            guard !reply.isError, let info = reply.text.first.flatMap(TmuxProtocol.windowInfo) else { return }
            handle(info)
        }
    }

    // MARK: - Windows

    /// The session's chip says tmux, so a window keeps its own name.

    private func open(_ info: TmuxProtocol.WindowInfo, focus: Bool) {
        guard !ended, windows[info.id] == nil, let host, let layout = TmuxProtocol.parseLayout(info.layout) else {
            return
        }
        let programs = linkNewPanes(layout, window: info.id)
        let tree = tree(for: layout)
        guard
            let workspace = host.tmuxOpenWorkspace(
                window: info.id, name: info.name, tree: tree, programs: programs, focus: focus)
        else {
            for pane in panes.values where pane.window == info.id { drop(pane) }
            return
        }
        windows[info.id] = WindowLink(
            workspace: workspace, tree: tree, name: info.name, activePane: info.activePane, zoomed: info.zoomed)
        if let active = panes[info.activePane], active.window == info.id {
            host.tmuxFocusPane(active.id, workspace: workspace)
            if info.zoomed { host.tmuxSetZoom(workspace: workspace, pane: active.id) }
        }
        noteSizes(layout)
        changed()
    }

    private func apply(layout text: String, window: String, zoomed: Bool) {
        guard let layout = TmuxProtocol.parseLayout(text), var link = windows[window] else { return }
        let ids = Set(layout.paneIDs)
        let programs = linkNewPanes(layout, window: window)
        link.tree = tree(for: layout)
        windows[window] = link
        closePanes(where: { $0.window == window && !ids.contains($0.tmuxID) }) {
            host?.tmuxApplyLayout(workspace: link.workspace, tree: link.tree, programs: programs)
        }
        if link.zoomed != zoomed {
            windows[window]?.zoomed = zoomed
            let pane = zoomed ? panes[link.activePane].flatMap { $0.window == window ? $0.id : nil } : nil
            host?.tmuxSetZoom(workspace: link.workspace, pane: pane)
        }
        noteSizes(layout)
    }

    private func close(window: String) {
        guard let link = windows.removeValue(forKey: window) else { return }
        closePanes(where: { $0.window == window }) { host?.tmuxCloseWorkspace(link.workspace) }
        changed()
    }

    /// Coalesces the windows opened or closed in one batch into one `onChange`.
    private func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changePending = false
            self.onChange?()
        }
    }

    /// Links the layout's panes Boo doesn't show yet; returns each new pane's program.
    private func linkNewPanes(_ layout: TmuxProtocol.Layout, window: String) -> [UUID: String] {
        var programs: [UUID: String] = [:]
        for tmuxID in layout.paneIDs {
            if let known = panes[tmuxID] {
                if known.window == window { continue }
                // Moved here from another window (join-pane, break-pane): it gets a
                // new Boo pane here; that window's layout drops the old one.
                known.closing = true
                drop(known)
            }
            let pane = link(tmuxID, window: window)
            programs[pane.id] = pane.command
        }
        return programs
    }

    /// Marks the matching panes as closing so their bridge disconnects don't
    /// kill them in tmux, runs `hostUpdate`, then forgets them.
    private func closePanes(where matches: (PaneLink) -> Bool, around hostUpdate: () -> Void) {
        let gone = panes.values.filter(matches)
        for pane in gone { pane.closing = true }
        hostUpdate()
        for pane in gone { drop(pane) }
    }

    /// The layout as a tree, minus panes the user already closed in Boo.
    private func tree(for layout: TmuxProtocol.Layout) -> SplitTree {
        var tree = TmuxProtocol.splitTree(layout) { panes[$0]?.id ?? UUID() }
        for pane in panes.values where pane.closing {
            if let smaller = tree.removing(leafID: pane.id) { tree = smaller }
        }
        return tree
    }

    private func noteSizes(_ layout: TmuxProtocol.Layout) {
        for (tmuxID, size) in layout.paneSizes { panes[tmuxID]?.tmuxSize = size }
        settleUntil = Date().addingTimeInterval(Self.layoutSettle)
        scheduleSizeSync(after: Self.layoutSettle + 0.05)
    }

    // MARK: - Panes

    private func link(_ tmuxID: String, window: String) -> (id: UUID, command: String) {
        let id = UUID()
        let registration = bridges.register { [weak self] event in self?.bridge(event, pane: tmuxID, id: id) }
        let pane = PaneLink(id: id, tmuxID: tmuxID, window: window, token: registration.token)
        panes[tmuxID] = pane
        capture(pane, history: true)
        return (id, registration.command)
    }

    /// Redraws the pane from tmux's copy of its screen (and scrollback, with
    /// `history`), then lets its output through.
    private func capture(_ pane: PaneLink, history: Bool) {
        let tmuxID = pane.tmuxID
        let lines = options().historyLines
        // -C octal-escapes ESC: a raw ESC in the reply would end the control mode DCS.
        let start = history && lines > 0 ? " -S -\(lines)" : ""
        send("capture-pane -p -e -C -q -J -t \(tmuxID)\(start)", quiet: true) { [weak self, weak pane] reply in
            guard let self, let pane, case .capturing = pane.phase else { return }
            pane.phase = .awaitingCursor
            pane.screen = reply.isError ? [] : reply.lines.map { TmuxProtocol.unescape($0) }
            self.send("display -p -t \(tmuxID) \"#{cursor_x} #{cursor_y}\"", quiet: true) {
                [weak self, weak pane] reply in
                guard let self, let pane, case .awaitingCursor = pane.phase else { return }
                pane.phase = .live
                self.deliver(
                    TmuxProtocol.redraw(lines: pane.screen, cursor: reply.isError ? nil : reply.text.first), to: pane)
                if !pane.held.isEmpty { self.deliver(pane.held, to: pane) }
                pane.screen = []
                pane.held = []
            }
        }
    }

    private func drop(_ pane: PaneLink) {
        panes[pane.tmuxID] = nil
        bridges.unregister(pane.token)
    }

    private func output(_ data: [UInt8], to tmuxID: String) {
        guard let pane = panes[tmuxID] else { return }
        let data = pane.names.filter(data)
        switch pane.phase {
        case .capturing:
            break
        case .awaitingCursor:
            pane.held += data
        case .live:
            deliver(data, to: pane)
        }
    }

    private func deliver(_ bytes: [UInt8], to pane: PaneLink) {
        if pane.connected {
            outgoing[pane.token, default: []] += bytes
        } else if pane.pending.count + bytes.count <= Self.maxPending {
            pane.pending += bytes
        }
    }

    private func bridge(_ event: TmuxBridgeServer.Event, pane tmuxID: String, id: UUID) {
        // `id` tells a pane that moved windows from its old bridge, still closing.
        guard let pane = panes[tmuxID], pane.id == id else { return }
        switch event {
        case .connected:
            pane.connected = true
            if !pane.pending.isEmpty {
                bridges.send(pane.token, pane.pending)
                pane.pending = []
            }
        case .input(let bytes):
            guard !ended else { return }
            for command in TmuxProtocol.sendKeys(pane: tmuxID, bytes: bytes) { send(command, quiet: true) }
        case .resize(let size):
            pane.bridgeSize = size
            sizingWindow = pane.window
            scheduleSizeSync(after: 0.1)
        case .disconnected:
            pane.connected = false
            // The user closed the pane in Boo: close it in tmux too.
            guard !pane.closing, !ended else { return }
            pane.closing = true
            send("kill-pane -t \(tmuxID)", quiet: true)
        }
    }

    // MARK: - Size

    private func scheduleSizeSync(after delay: TimeInterval) {
        sizeSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncSizes() }
        sizeSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Sizes the tmux client to fit Boo's panes, then each tmux pane to its Boo pane.
    private func syncSizes() {
        guard started, !ended else { return }
        let sizes = Dictionary(
            panes.values.compactMap { p in p.bridgeSize.map { (p.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if let window = sizingWindow ?? windows.keys.first, let link = windows[window] {
            // A zoomed pane fills the window: its size is the client's.
            let zoomedSize = panes[link.activePane].flatMap { $0.window == window ? $0.bridgeSize : nil }
            if let total = link.zoomed ? zoomedSize : TmuxProtocol.clientSize(link.tree, sizes: sizes) {
                setClientSize(total)
            }
        }
        guard Date() >= settleUntil else { return }
        // resize-pane would unzoom a zoomed window.
        for pane in panes.values where !pane.closing && windows[pane.window]?.zoomed != true {
            guard let want = pane.bridgeSize, want != pane.tmuxSize, want != pane.requestedSize else { continue }
            pane.requestedSize = want
            send("resize-pane -t \(pane.tmuxID) -x \(want.columns) -y \(want.rows)")
        }
    }

    private func setClientSize(_ size: TmuxProtocol.CellSize) {
        guard size != clientSize, size.columns > 0, size.rows > 0 else { return }
        clientSize = size
        send("refresh-client -C \(size.columns)x\(size.rows)", quiet: true)
    }

    // MARK: - Reattach on launch

    private static let attachedAtQuitKey = "tmuxSessionsAttachedAtQuit"

    /// Notes the sessions shown at quit, for `tmuxReattachOnLaunch`.
    private static func rememberAttachedSessions() {
        let sessions = live.compactMap(\.client).filter { !$0.ended }.compactMap { client in
            client.session.map { ["session": $0, "host": client.remoteHost ?? ""] }
        }
        UserDefaults.standard.set(sessions, forKey: attachedAtQuitKey)
    }

    /// The sessions shown when Boo last quit, as (session, ssh host); read once.
    static func takeSessionsAttachedAtQuit() -> [(session: String, host: String?)] {
        let stored = UserDefaults.standard.array(forKey: attachedAtQuitKey) as? [[String: String]] ?? []
        UserDefaults.standard.removeObject(forKey: attachedAtQuitKey)
        return stored.compactMap { entry in
            guard let session = entry["session"], !session.isEmpty else { return nil }
            let host = entry["host"] ?? ""
            return (session, host.isEmpty ? nil : host)
        }
    }
}
