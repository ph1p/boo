import AppKit
import WebKit

/// `boo browser`: lets agents in Boo terminals drive browser tabs, mainly to
/// test the web app they are building. An agent opens tabs in the background
/// of its own pane and controls those freely; any other browser tab needs the
/// user's approval (see `OrchestratorGate.decideBrowser`).
@MainActor
final class AgentBrowser {
    static let shared = AgentBrowser()

    struct Failure: Error {
        var message: String
    }

    /// The browser tab each caller used last: the default target.
    private var lastTab: [UUID: UUID] = [:]
    /// Hosts a background tab while a command runs: WebKit throttles and
    /// cannot snapshot a page outside a window.
    private lazy var stage: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        return window
    }()

    static let loadTimeout: TimeInterval = 10
    static let readLimit = 20000

    // MARK: - Targets

    /// Every open browser tab, in window order.
    func browserTabs() -> [(tab: Pane.Tab, location: AgentInbox.Location)] {
        var result: [(Pane.Tab, AgentInbox.Location)] = []
        for controller in WindowManager.shared.controllers {
            for workspace in controller.appState.workspaces {
                for pane in workspace.panes.values {
                    for (index, tab) in pane.tabs.enumerated() where tab.contentType == .browser {
                        result.append(
                            (
                                tab,
                                AgentInbox.Location(
                                    controller: controller, workspace: workspace, pane: pane, tabIndex: index)
                            ))
                    }
                }
            }
        }
        return result
    }

    /// A tab id, a unique id prefix (as `boo browser ls` prints), or with no
    /// reference the caller's last tab. nil when nothing matches.
    func tab(matching reference: String?, caller: UUID?) -> UUID? {
        let tabs = browserTabs().map(\.tab.id)
        guard let reference = reference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            return caller.flatMap { lastTab[$0] }.flatMap { tabs.contains($0) ? $0 : nil }
        }
        if let id = UUID(uuidString: reference) { return tabs.contains(id) ? id : nil }
        let prefix = reference.lowercased()
        let matches = tabs.filter { $0.uuidString.lowercased().hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Commands

    func handle(cmd: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                guard AppSettings.shared.agentBrowserAccessEnabled else {
                    throw Failure(message: "agent browser access is off (Settings › Browser)")
                }
                let caller = CapabilityTokens.shared.resolve(json["token"] as? String)?.tabID
                var result = try await run(cmd: cmd, json: json, caller: caller)
                result["ok"] = true
                reply(result)
            } catch let failure as Failure {
                reply(["ok": false, "error": failure.message])
            } catch {
                reply(["ok": false, "error": Self.message(of: error)])
            }
        }
    }

    private func run(cmd: String, json: [String: Any], caller: UUID?) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch cmd {
        case "browser_list":
            return ["tabs": list(caller: caller)]
        case "browser_open":
            guard let caller else { throw Failure(message: "needs the BOO_TOKEN of a Boo terminal") }
            let url = try Self.url(string("url") ?? "about:blank")
            let id = try open(url, beside: caller, show: json["show"] as? Bool ?? false)
            let view = try browserView(id)
            if !BrowserContentView.isBlank(url) { await whileStaged(view) { await self.waitForLoad(view) } }
            return page(id, view)
        default:
            break
        }

        guard let id = (json["tab_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw Failure(message: "no browser tab: open one with `boo browser open <url>`")
        }
        if let caller { lastTab[caller] = id }
        let view = try browserView(id)
        return try await whileStaged(view) { () async throws -> [String: Any] in
            switch cmd {
            case "browser_navigate":
                switch string("action") {
                case "back": view.goBack()
                case "forward": view.goForward()
                case "reload": view.reload()
                default:
                    guard let target = string("url") else { throw Failure(message: "missing url") }
                    view.navigate(to: try Self.url(target))
                }
                await self.waitForLoad(view)
                return self.page(id, view)
            case "browser_read":
                let html = string("format") == "html"
                let limit = max(1, json["max_chars"] as? Int ?? Self.readLimit)
                guard
                    let text = try await self.evaluate(
                        Self.readScript, ["selector": string("selector") ?? "", "html": html], in: view) as? String
                else { throw Failure(message: "no element matches \(string("selector") ?? "the page")") }
                var result = self.page(id, view)
                result["text"] = String(text.prefix(limit))
                result["truncated"] = text.count > limit
                return result
            case "browser_screenshot":
                var result = self.page(id, view)
                result["path"] = try await self.screenshot(view, to: string("path"))
                return result
            case "browser_console":
                let entries =
                    try await self.evaluate(Self.consoleScript, ["clear": json["clear"] as? Bool ?? false], in: view)
                    as? [[String: Any]]
                guard let entries else {
                    throw Failure(message: "no console log: the page loaded before browser access was on, reload it")
                }
                return ["entries": entries.map { ["level": $0["level"] ?? "log", "text": $0["text"] ?? ""] }]
            case "browser_click":
                let selector = string("selector") ?? ""
                let text = string("text") ?? ""
                guard !selector.isEmpty || !text.isEmpty else { throw Failure(message: "missing selector or text") }
                guard
                    let clicked = try await self.evaluate(
                        Self.clickScript, ["selector": selector, "text": text], in: view) as? String
                else { throw Failure(message: "nothing to click matches \(selector.isEmpty ? text : selector)") }
                await self.settle(view)
                var result = self.page(id, view)
                result["clicked"] = clicked
                return result
            case "browser_type":
                let arguments: [String: Any] = [
                    "selector": string("selector") ?? "", "text": json["text"] as? String ?? "",
                    "submit": json["submit"] as? Bool ?? false
                ]
                guard try await self.evaluate(Self.typeScript, arguments, in: view) as? String != nil else {
                    throw Failure(message: "no input matches \(string("selector") ?? "the focused element")")
                }
                await self.settle(view)
                return self.page(id, view)
            case "browser_eval":
                guard let code = json["js"] as? String, !code.isEmpty else { throw Failure(message: "missing js") }
                let value = try await self.evaluate(Self.evalScript, ["code": code], in: view)
                return ["result": value as? String ?? ""]
            case "browser_close":
                try self.close(id)
                return [:]
            default:
                throw Failure(message: "unknown command \(cmd)")
            }
        }
    }

    private func page(_ id: UUID, _ view: BrowserContentView) -> [String: Any] {
        [
            "tab_id": id.uuidString, "url": view.webView?.url?.absoluteString ?? view.url.absoluteString,
            "title": view.webView?.title ?? ""
        ]
    }

    private func list(caller: UUID?) -> [[String: Any]] {
        browserTabs().map { tab, location in
            var url = ""
            if case .browser(let state) = tab.state.contentState { url = state.url.absoluteString }
            if let view = paneView(location)?.browserView(for: tab.id) { url = view.url.absoluteString }
            return [
                "tab_id": tab.id.uuidString, "url": url, "title": tab.title,
                "owned": caller.map { CapabilityTokens.shared.owns($0, tab.id) } ?? false
            ]
        }
    }

    // MARK: - Tabs

    private func paneView(_ location: AgentInbox.Location) -> PaneView? {
        location.controller.workspacePaneViews[location.workspace.id]?[location.pane.id]
    }

    private func browserView(_ id: UUID) throws -> BrowserContentView {
        guard let location = AgentInbox.locateInWindows(id),
            location.pane.tabs[location.tabIndex].contentType == .browser
        else { throw Failure(message: "no browser tab \(id.uuidString)") }
        guard let view = paneView(location)?.browserView(for: id) else {
            throw Failure(message: "the tab has not loaded since Boo started: click it once")
        }
        return view
    }

    /// A browser tab in the caller's pane, behind the tab it shows (or shown with `show`).
    private func open(_ url: URL, beside caller: UUID, show: Bool) throws -> UUID {
        guard let location = AgentInbox.locateInWindows(caller), !location.pane.tmuxOwned,
            let paneView = paneView(location)
        else { throw Failure(message: "run this in a Boo terminal tab") }
        let pane = location.pane
        let shown = pane.activeTab?.id
        guard let id = paneView.addNewTab(contentType: .browser, url: url, focus: false) else {
            throw Failure(message: "could not open a browser tab")
        }
        if !show, let shown, let index = pane.tabs.firstIndex(where: { $0.id == shown }) {
            paneView.activateTab(index, focus: false)
        }
        paneView.groupsChanged()
        location.controller.saveSession()
        CapabilityTokens.shared.markOwned(id, by: caller)
        lastTab[caller] = id
        return id
    }

    private func close(_ id: UUID) throws {
        guard let location = AgentInbox.locateInWindows(id), let paneView = paneView(location) else {
            throw Failure(message: "no browser tab \(id.uuidString)")
        }
        guard location.pane.tabs.count > 1 else { throw Failure(message: "the last tab of a pane stays open") }
        paneView.closeTab(at: location.tabIndex)
        paneView.groupsChanged()
        location.controller.refreshStatusBar()
        location.controller.saveSession()
        CapabilityTokens.shared.disown(id)
        ApprovalCenter.shared.revokeGrants(tab: id)
    }

    // MARK: - Page

    /// Runs `body` with the view in a window: its own, or the offscreen stage.
    private func whileStaged<T>(_ view: BrowserContentView, _ body: () async throws -> T) async rethrows -> T {
        guard view.window == nil else { return try await body() }
        let host = stage.contentView!
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        stage.orderBack(nil)
        defer {
            // The user may have opened the tab meanwhile; then it lives in its pane.
            if view.superview === host { view.removeFromSuperview() }
            if host.subviews.isEmpty { stage.orderOut(nil) }
        }
        return try await body()
    }

    private func waitForLoad(_ view: BrowserContentView, timeout: TimeInterval = loadTimeout) async {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = Date().addingTimeInterval(timeout)
        while view.webView?.isLoading == true, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// After a click or input: wait for a navigation it may have started.
    private func settle(_ view: BrowserContentView) async {
        await waitForLoad(view, timeout: Self.loadTimeout)
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func evaluate(_ body: String, _ arguments: [String: Any], in view: BrowserContentView) async throws -> Any?
    {
        guard let webView = view.webView else { throw Failure(message: "the tab has no page") }
        let result: ScriptResult = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: ScriptResult(value: value is NSNull ? nil : value))
                case .failure(let error): continuation.resume(throwing: Failure(message: Self.message(of: error)))
                }
            }
        }
        return result.value
    }

    /// A script's result: plist types only, handed over on the main actor.
    private struct ScriptResult: @unchecked Sendable {
        var value: Any?
    }

    private func screenshot(_ view: BrowserContentView, to path: String?) async throws -> String {
        guard let webView = view.webView else { throw Failure(message: "the tab has no page") }
        view.layoutSubtreeIfNeeded()
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: Failure(message: error.map(Self.message) ?? "snapshot failed"))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw Failure(message: "could not encode the screenshot") }
        let file: URL
        if let path {
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boo-browser")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        }
        try png.write(to: file)
        return file.path
    }

    // MARK: - Helpers

    /// `localhost:3000` and `example.com` get a scheme like the address bar gives them.
    static func url(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("data:") {
            guard let url = URL(string: text) else { throw Failure(message: "bad url \(text)") }
            return url
        }
        let local = ["localhost", "127.", "0.0.0.0", "[::1]"].contains { text.hasPrefix($0) }
        guard let url = URL(string: (local ? "http://" : "https://") + text), url.host != nil else {
            throw Failure(message: "bad url \(text)")
        }
        return url
    }

    static func message(of error: Error) -> String {
        let error = error as NSError
        if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return "JavaScript error: \(message)"
        }
        return error.localizedDescription
    }

    // MARK: - Scripts

    /// Collects console output and uncaught errors in `window.__booConsole`.
    static let consoleCapture = """
        (() => {
          if (window.__booConsole) return;
          const log = [];
          Object.defineProperty(window, '__booConsole', { value: log });
          const text = (value) => {
            if (value instanceof Error) return value.stack || String(value);
            if (typeof value === 'object' && value !== null) {
              try { return JSON.stringify(value); } catch (e) { return String(value); }
            }
            return String(value);
          };
          const push = (level, args) => {
            log.push({ level, text: Array.from(args).map(text).join(' ').slice(0, 4000) });
            if (log.length > 500) log.splice(0, log.length - 500);
          };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            console[level] = function (...args) { push(level, args); return original.apply(this, args); };
          }
          addEventListener('error', (e) => push('error', [e.error || `${e.message} at ${e.filename}:${e.lineno}`]));
          addEventListener('unhandledrejection', (e) => push('error', ['Unhandled rejection:', e.reason]));
        })();
        """

    static let readScript = """
        const root = selector ? document.querySelector(selector) : (html ? document.documentElement : document.body);
        if (!root) return null;
        return html ? root.outerHTML : root.innerText;
        """

    static let consoleScript = """
        const log = window.__booConsole;
        if (!log) return null;
        const entries = log.slice();
        if (clear) log.length = 0;
        return entries;
        """

    static let clickScript = """
        let el = selector ? document.querySelector(selector) : null;
        if (!el && text) {
          const wanted = text.trim().toLowerCase();
          const candidates = document.querySelectorAll(
            'a, button, [role=button], [role=link], [role=tab], [role=menuitem], input[type=submit], input[type=button], label, summary');
          const label = (c) => (c.innerText || c.value || c.getAttribute('aria-label') || '').trim().toLowerCase();
          el = Array.from(candidates).find((c) => label(c) === wanted)
            || Array.from(candidates).find((c) => label(c).includes(wanted));
        }
        if (!el) return null;
        el.scrollIntoView({ block: 'center' });
        el.click();
        return (el.innerText || el.value || el.getAttribute('aria-label') || el.tagName.toLowerCase()).trim().slice(0, 80);
        """

    /// Sets the value through the native setter so React and friends see it.
    static let typeScript = """
        const el = selector ? document.querySelector(selector) : document.activeElement;
        if (!el || el === document.body) return null;
        el.focus();
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : el instanceof HTMLInputElement ? HTMLInputElement.prototype
          : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : null;
        if (proto) Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
        else if (el.isContentEditable) el.textContent = text;
        else return null;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        if (submit) {
          const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
          el.dispatchEvent(new KeyboardEvent('keyup', init));
          if (go && el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
        }
        return el.tagName.toLowerCase();
        """

    /// Evaluates `code` like the console does and returns the value as text.
    static let evalScript = """
        let value = (0, eval)(code);
        if (value instanceof Promise) value = await value;
        if (value === undefined) return 'undefined';
        if (typeof value === 'string') return value;
        if (value instanceof Element) return value.outerHTML.slice(0, 4000);
        const seen = new WeakSet();
        try {
          return JSON.stringify(value, (key, item) => {
            if (typeof item === 'function') return '[function]';
            if (typeof item === 'object' && item !== null) {
              if (seen.has(item)) return '[circular]';
              seen.add(item);
            }
            return item;
          }, 2) ?? String(value);
        } catch (e) {
          return String(value);
        }
        """
}
