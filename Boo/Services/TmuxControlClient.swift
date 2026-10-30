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
    }

    private struct Block {
        let number: String
        let reply: ((Reply) -> Void)?
        var lines: [[UInt8]] = []
    }

    struct Reply {
        let lines: [[UInt8]]
        let isError: Bool
        var text: [String] { lines.map { String(decoding: $0, as: UTF8.self) } }
    }

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
    /// Reply handlers in command order; `replyHead` is the next one due.
    private var replies: [((Reply) -> Void)?] = []
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
                for client in TmuxControlClient.live.compactMap(\.client) { client.ended = true }
            }
        }
    }

    /// The client showing `workspace`, if it is a tmux window.
    static func owning(workspace: UUID) -> TmuxControlClient? {
        live.lazy.compactMap(\.client).first { $0.windows.values.contains { $0.workspace == workspace } }
    }

    /// The attached session's name, once tmux reported it.
    private(set) var session: String?
    /// Called once per run loop turn in which the session or its windows changed.
    var onChange: (() -> Void)?
    private var changePending = false

    /// This session's windows in tmux order, with the workspace showing each.
    var windowList: [(workspace: UUID, name: String)] {
        windows.sorted { Self.order($0.key) < Self.order($1.key) }.map { ($0.value.workspace, $0.value.name) }
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
                open.reply?(Reply(lines: open.lines, isError: false))
            case .error(let n) where n == open.number:
                block = nil
                open.reply?(Reply(lines: open.lines, isError: true))
            default:
                open.lines.append(raw)
                block = open
            }
            return
        }
        switch TmuxProtocol.parse(raw) {
        case .begin(let number, let fromClient):
            block = Block(number: number, reply: fromClient ? nextReply() : nil)
        case .output(let pane, let data):
            output(data, to: pane)
        case .layoutChange(let window, let layout):
            if windows[window] != nil { apply(layout: layout, window: window) }
        case .windowAdd(let window):
            guard started else { return }
            send("display -p -t \(window) \"\(TmuxProtocol.windowFormat)\"") { [weak self] reply in
                guard let self, !reply.isError, let info = reply.text.first.flatMap(TmuxProtocol.windowInfo) else {
                    return
                }
                self.open(info, focus: true)
            }
        case .windowClose(let window):
            close(window: window)
        case .windowRenamed(let window, let name):
            guard let workspace = windows[window]?.workspace else { return }
            windows[window]?.name = name
            host?.tmuxRenameWorkspace(workspace, name: Self.title(name))
            changed()
        case .sessionChanged(_, let name):
            if started {
                for window in Array(windows.keys) { close(window: window) }
            }
            session = name
            start()
            changed()
        case .exit, .end, .error, .other:
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
        guard let pane = panes.values.first(where: { $0.id == id }) else { return }
        let flags: String
        switch edge {
        case .right: flags = "-h"
        case .left: flags = "-h -b"
        case .down: flags = "-v"
        case .up: flags = "-v -b"
        }
        send("split-window \(flags) -t \(pane.tmuxID)")
    }

    func newWindow() {
        send("new-window")
    }

    func show(workspace: UUID) {
        host?.tmuxShowWorkspace(workspace)
    }

    // MARK: - Commands

    private func send(_ command: String, reply: ((Reply) -> Void)? = nil) {
        replies.append(reply)
        guard started else { return held.append(command) }
        gateway?.writeTmuxCommand(command)
    }

    private func nextReply() -> ((Reply) -> Void)? {
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
        send("list-windows -F \"\(TmuxProtocol.windowFormat)\"") { [weak self] reply in
            guard let self, !reply.isError else { return }
            for info in reply.text.compactMap(TmuxProtocol.windowInfo) { self.open(info, focus: info.active) }
        }
    }

    // MARK: - Windows

    private static func title(_ name: String) -> String { "tmux: \(name)" }

    private func open(_ info: TmuxProtocol.WindowInfo, focus: Bool) {
        guard !ended, windows[info.id] == nil, let host, let layout = TmuxProtocol.parseLayout(info.layout) else {
            return
        }
        let programs = linkNewPanes(layout, window: info.id)
        let tree = tree(for: layout)
        guard
            let workspace = host.tmuxOpenWorkspace(
                window: info.id, name: Self.title(info.name), tree: tree, programs: programs, focus: focus)
        else {
            for pane in panes.values where pane.window == info.id { drop(pane) }
            return
        }
        windows[info.id] = WindowLink(workspace: workspace, tree: tree, name: info.name)
        noteSizes(layout)
        changed()
    }

    private func apply(layout text: String, window: String) {
        guard let layout = TmuxProtocol.parseLayout(text), var link = windows[window] else { return }
        let ids = Set(layout.paneIDs)
        let programs = linkNewPanes(layout, window: window)
        link.tree = tree(for: layout)
        windows[window] = link
        closePanes(where: { $0.window == window && !ids.contains($0.tmuxID) }) {
            host?.tmuxApplyLayout(workspace: link.workspace, tree: link.tree, programs: programs)
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
        for tmuxID in layout.paneIDs where panes[tmuxID] == nil {
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
        let registration = bridges.register { [weak self] event in self?.bridge(event, pane: tmuxID) }
        let pane = PaneLink(id: id, tmuxID: tmuxID, window: window, token: registration.token)
        panes[tmuxID] = pane
        // -C octal-escapes ESC: a raw ESC in the reply would end the control mode DCS.
        send("capture-pane -p -e -C -q -J -t \(tmuxID) -S -1000") { [weak self, weak pane] reply in
            guard let self, let pane else { return }
            pane.phase = .awaitingCursor
            pane.screen = reply.isError ? [] : reply.lines.map { TmuxProtocol.unescape($0) }
            self.send("display -p -t \(tmuxID) \"#{cursor_x} #{cursor_y}\"") { [weak self, weak pane] reply in
                guard let self, let pane, case .awaitingCursor = pane.phase else { return }
                pane.phase = .live
                self.deliver(
                    TmuxProtocol.redraw(lines: pane.screen, cursor: reply.isError ? nil : reply.text.first), to: pane)
                if !pane.held.isEmpty { self.deliver(pane.held, to: pane) }
                pane.screen = []
                pane.held = []
            }
        }
        return (id, registration.command)
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

    private func bridge(_ event: TmuxBridgeServer.Event, pane tmuxID: String) {
        guard let pane = panes[tmuxID] else { return }
        switch event {
        case .connected:
            pane.connected = true
            if !pane.pending.isEmpty {
                bridges.send(pane.token, pane.pending)
                pane.pending = []
            }
        case .input(let bytes):
            guard !ended else { return }
            for command in TmuxProtocol.sendKeys(pane: tmuxID, bytes: bytes) { send(command) }
        case .resize(let size):
            pane.bridgeSize = size
            sizingWindow = pane.window
            scheduleSizeSync(after: 0.1)
        case .disconnected:
            pane.connected = false
            // The user closed the pane in Boo: close it in tmux too.
            guard !pane.closing, !ended else { return }
            pane.closing = true
            send("kill-pane -t \(tmuxID)")
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
        if let window = sizingWindow ?? windows.keys.first, let link = windows[window],
            let total = TmuxProtocol.clientSize(link.tree, sizes: sizes)
        {
            setClientSize(total)
        }
        guard Date() >= settleUntil else { return }
        for pane in panes.values where !pane.closing {
            guard let want = pane.bridgeSize, want != pane.tmuxSize, want != pane.requestedSize else { continue }
            pane.requestedSize = want
            send("resize-pane -t \(pane.tmuxID) -x \(want.columns) -y \(want.rows)")
        }
    }

    private func setClientSize(_ size: TmuxProtocol.CellSize) {
        guard size != clientSize, size.columns > 0, size.rows > 0 else { return }
        clientSize = size
        send("refresh-client -C \(size.columns)x\(size.rows)")
    }
}
