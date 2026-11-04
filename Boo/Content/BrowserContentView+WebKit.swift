import Cocoa
import WebKit

// MARK: - WKNavigationDelegate

@MainActor
extension BrowserContentView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    // Toolbar state (URL, title, loading, history) follows KVO in
    // syncWebViewState; these callbacks only handle their own side effects.

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
        webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !findNeedle.isEmpty {
            find(findNeedle)
        }
        // Record in browser history after title + URL are both known
        if let url = webView.url {
            BrowserHistory.shared.record(title: webView.title ?? "", url: url)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !BrowserErrorView.isSilent(error) else { return }
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's renderer crashed or was killed under memory pressure;
        // reloading brings it back instead of leaving a dead white view.
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

// WebKit marks these handlers @MainActor only from the macOS 27 SDK (Swift 6.4).
// A mismatched type is a "near miss": the method is never called, so JS
// alert()/confirm() silently break. Match whichever SDK we build against.
#if compiler(>=6.4)
    typealias JSAlertCompletion = @MainActor @Sendable () -> Void
    typealias JSConfirmCompletion = @MainActor @Sendable (Bool) -> Void
#else
    typealias JSAlertCompletion = @Sendable () -> Void
    typealias JSConfirmCompletion = @Sendable (Bool) -> Void
#endif

@MainActor
extension BrowserContentView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        openURLInNewTab(url)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        onCloseRequested?()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping JSAlertCompletion
    ) {
        guard let window else { return completionHandler() }
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping JSConfirmCompletion
    ) {
        guard let window else { return completionHandler(false) }
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard let window else { return completionHandler(nil) }
        let alert = Self.pageAlert(message: prompt, frame: frame)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// Page dialogs name the site they came from so they can't pose as Boo.
    private static func pageAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

// MARK: - WKDownloadDelegate

@MainActor
extension BrowserContentView: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destination = Self.downloadDestinationURL(
            in: downloadsDirectoryURL(),
            suggestedFilename: suggestedFilename
        )
        completedDownloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        else { return }
        // Bounce the Downloads stack in the Dock like Safari does.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: destination.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        _ = completedDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }
}
