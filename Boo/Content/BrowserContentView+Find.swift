import Cocoa
import WebKit

extension BrowserContentView {
    // MARK: - Find in Page

    private static let countMatchesScript = """
        const text = document.body ? document.body.innerText.toLowerCase() : "";
        const n = needle.toLowerCase();
        let count = 0;
        let i = text.indexOf(n);
        while (i !== -1) { count++; i = text.indexOf(n, i + n.length); }
        return count;
        """

    /// Start a new search. WKWebView's find API reports only found / not
    /// found, so the total comes from counting matches in the page text.
    func find(_ needle: String) {
        resetFind(needle: needle)
        let generation = findGeneration
        guard webView != nil, !needle.isEmpty else {
            clearPageSelection()
            onFindMatches?(-1, -1)
            return
        }
        Task { @MainActor [weak self] in
            // Called per keystroke and counting re-reads the whole page text,
            // so wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, generation == self.findGeneration else { return }
            self.countAndStepFind(needle, generation: generation)
        }
    }

    private func countAndStepFind(_ needle: String, generation: Int) {
        webView?.callAsyncJavaScript(
            Self.countMatchesScript, arguments: ["needle": needle], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self, generation == self.findGeneration else { return }
            let total = ((try? result.get()) as? NSNumber)?.intValue ?? 0
            self.findTotal = total
            guard total > 0 else {
                self.clearPageSelection()
                self.onFindMatches?(-1, 0)
                return
            }
            // Start from the top of the page, not after the previous match.
            self.clearPageSelection { [weak self] in
                self?.stepFind(forward: true, generation: generation)
            }
        }
    }

    func findNext(_ forward: Bool) {
        guard findTotal > 0 else { return }
        stepFind(forward: forward, generation: findGeneration)
    }

    func endFind() {
        resetFind(needle: "")
        clearPageSelection()
    }

    /// Invalidates in-flight find callbacks (via the generation) and clears counts.
    private func resetFind(needle: String) {
        findGeneration += 1
        findNeedle = needle
        findTotal = 0
        findIndex = -1
    }

    private func stepFind(forward: Bool, generation: Int) {
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        config.backwards = !forward
        webView?.find(findNeedle, configuration: config) { [weak self] result in
            guard let self, generation == self.findGeneration, result.matchFound, self.findTotal > 0 else { return }
            self.findIndex =
                forward
                ? (self.findIndex + 1) % self.findTotal
                : (self.findIndex - 1 + self.findTotal) % self.findTotal
            self.onFindMatches?(self.findIndex, self.findTotal)
        }
    }

    private func clearPageSelection(then completion: (@MainActor () -> Void)? = nil) {
        guard let webView else { return }
        webView.evaluateJavaScript("window.getSelection().removeAllRanges(); 0", in: nil, in: .defaultClient) { _ in
            completion?()
        }
    }
}
