import SwiftUI
import WebKit

/// A SwiftUI wrapper around WKWebView that self-sizes to its HTML content.
struct MarkdownWebView: NSViewRepresentable {
    let html: String

    @Binding var contentHeight: CGFloat

    init(html: String, contentHeight: Binding<CGFloat>) {
        self.html = html
        self._contentHeight = contentHeight
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        loadContent(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadContent(in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func loadContent(in webView: WKWebView) {
        let document = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            \(Self.css)
            </style>
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
        webView.loadHTMLString(document, baseURL: nil)
    }

    private static let css = """
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 11px;
            line-height: 1.5;
            color: #1d1d1f;
            padding: 8px;
            -webkit-font-smoothing: antialiased;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #f5f5f7; }
            code, pre { background: rgba(255,255,255,0.08); }
            blockquote { border-left-color: #48484a; }
            a { color: #64d2ff; }
            table th { background: rgba(255,255,255,0.06); }
            table td, table th { border-color: #48484a; }
            hr { border-color: #48484a; }
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 12px;
            margin-bottom: 4px;
            font-weight: 600;
        }
        h1 { font-size: 16px; }
        h2 { font-size: 14px; }
        h3 { font-size: 12px; }
        p { margin-bottom: 8px; }
        a { color: #0071e3; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: "SF Mono", Menlo, monospace;
            font-size: 10px;
            background: rgba(0,0,0,0.06);
            padding: 1px 4px;
            border-radius: 3px;
        }
        pre {
            background: rgba(0,0,0,0.06);
            padding: 8px;
            border-radius: 4px;
            overflow-x: auto;
            margin-bottom: 8px;
        }
        pre code { background: none; padding: 0; }
        ul, ol { padding-left: 20px; margin-bottom: 8px; }
        li { margin-bottom: 2px; }
        blockquote {
            border-left: 3px solid #d1d1d6;
            padding-left: 10px;
            color: #86868b;
            margin-bottom: 8px;
        }
        table {
            border-collapse: collapse;
            margin-bottom: 8px;
            width: 100%;
        }
        table th, table td {
            border: 1px solid #d1d1d6;
            padding: 4px 8px;
            text-align: left;
        }
        table th { background: rgba(0,0,0,0.03); font-weight: 600; }
        hr {
            border: none;
            border-top: 1px solid #d1d1d6;
            margin: 12px 0;
        }
        img { max-width: 100%; }
        del { text-decoration: line-through; }
        mark { background: #ffd60a; padding: 0 2px; border-radius: 2px; }
        input[type="checkbox"] { margin-right: 4px; }
        """

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: MarkdownWebView

        init(parent: MarkdownWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self.parent.contentHeight = height
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url
            {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
