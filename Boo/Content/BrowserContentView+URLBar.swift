import Cocoa
import WebKit

extension BrowserContentView {
    /// Turn address-bar input into a URL: explicit schemes and file paths load
    /// as-is, local hosts get http, anything that looks like a domain gets
    /// https, and everything else becomes a web search.
    ///
    /// Port shorthand: ":3000" always means localhost:3000; a bare "3000" does
    /// too when it is in `knownPorts` (a server running in a pane), and is a
    /// search otherwise.
    static func resolveInput(_ raw: String, knownPorts: Set<UInt16> = []) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let portDigits = input.hasPrefix(":") ? input.dropFirst() : Substring(input)
        if let port = UInt16(portDigits), port > 0, input.hasPrefix(":") || knownPorts.contains(port) {
            return URL(string: "http://localhost:\(port)")
        }

        if input.hasPrefix("/") || input == "~" || input.hasPrefix("~/") {
            return URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }

        if !input.contains(where: \.isWhitespace) {
            let lower = input.lowercased()
            if lower.contains("://") || ["about:", "data:", "mailto:", "file:"].contains(where: lower.hasPrefix),
                let url = URL(string: input), url.scheme != nil
            {
                return url
            }

            // `URL(string: "localhost:3000")` parses "localhost" as the scheme,
            // so inspect the host part by hand.
            let hostAndPort = lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            let host = hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isIPv4(host) {
                return URL(string: "http://\(input)")
            }
            if let tld = host.split(separator: ".").last, host.contains("."), tld.count >= 2,
                tld.allSatisfy(\.isLetter)
            {
                return URL(string: "https://\(input)")
            }
        }

        return searchURL(for: input)
    }

    static func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func isBlank(_ url: URL) -> Bool {
        url.absoluteString == "about:blank"
    }

    static func displayString(for url: URL) -> String {
        isBlank(url) ? "" : url.absoluteString
    }

    // MARK: - NSTextFieldDelegate (autocomplete)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        showAutocomplete(query: query)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        showAutocomplete(query: query)

        // Rescan once per edit (not per keystroke) and redraw if the servers
        // changed while the user is still in this field.
        let shown = PaneServerMonitor.shared.servers
        PaneServerMonitor.shared.refresh { [weak self] found in
            guard let self, found != shown, let urlBar = self.urlBar, urlBar.isFieldActive else { return }
            self.showAutocomplete(query: urlBar.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        autocompletePanel?.close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let event = NSApp.currentEvent
        if commandSelector == #selector(NSResponder.moveDown(_:))
            || commandSelector == #selector(NSResponder.moveUp(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:))
        {
            if let event, autocompletePanel?.handleKeyDown(with: event) == true {
                return true
            }
        }
        // Escape with no suggestions open: abandon the edit, like Safari.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            urlBar?.stringValue = Self.displayString(for: currentURL)
            if webView?.isHidden == false {
                window?.makeFirstResponder(webView)
            } else {
                urlBar?.currentEditor()?.selectAll(nil)
            }
            return true
        }
        return false
    }

    private func showAutocomplete(query: String) {
        guard let anchor = urlBarPill else { return }
        ensureAutocompletePanel()

        let entries = BrowserHistory.shared.entries
        let filtered: [BrowserHistoryEntry]
        if query.isEmpty {
            filtered = Array(entries.prefix(8))
        } else {
            filtered = entries.filter {
                $0.url.absoluteString.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
        }

        // Deduplicate by URL, preserving order (most recent first)
        var seen = Set<URL>()
        let deduped = filtered.filter { seen.insert($0.url).inserted }

        let servers = Self.serverItems(PaneServerMonitor.shared.servers, matching: query)
        let serverURLs = Set(servers.map(\.url))
        let history = deduped.lazy.filter { !serverURLs.contains($0.url) }.prefix(8)
            .map { URLAutocompletePanel.Item(title: $0.title, url: $0.url) }
        let matches = servers + history

        if matches.isEmpty {
            autocompletePanel?.close()
        } else {
            autocompletePanel?.show(below: anchor, items: matches)
        }
    }

    /// Suggestions for servers running in panes. All of them on an empty
    /// query; otherwise those whose address, port, process or pane matches.
    static func serverItems(_ servers: [PaneServer], matching query: String) -> [URLAutocompletePanel.Item] {
        let needle = query.hasPrefix(":") ? String(query.dropFirst()) : query
        return
            servers
            .filter { server in
                let fields = [server.hostLabel, server.url.absoluteString, server.processName, server.location]
                return needle.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            .map {
                URLAutocompletePanel.Item(title: $0.hostLabel, url: $0.url, subtitle: $0.detail, symbol: "server.rack")
            }
    }

    private func ensureAutocompletePanel() {
        guard autocompletePanel == nil else { return }
        autocompletePanel = URLAutocompletePanel()
        autocompletePanel?.onSelect = { [weak self] url in
            self?.navigate(to: url)
            self?.window?.makeFirstResponder(self?.webView)
        }
    }
}
