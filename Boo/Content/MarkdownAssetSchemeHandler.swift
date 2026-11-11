import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves local images to the markdown preview. The page loads with a
/// `boo-md://local/<path of the .md file>` base URL, so relative and absolute
/// image paths resolve to this scheme and WebKit can show them without
/// file-URL read access. Only image files are served: a markdown file may
/// contain raw HTML, so the handler must not hand out arbitrary files.
final class MarkdownAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "boo-md"
    private static let host = "local"

    static let servedExtensions: Set<String> = ContentType.imageExtensions.union(["svg", "apng"])

    /// The scheme URL for a local file path.
    static func url(forPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        return components.url
    }

    /// The local file path a `boo-md:` or `file:` URL points to.
    static func filePath(for url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case scheme: return url.host == host ? url.path : nil
        case "file": return url.path
        default: return nil
        }
    }

    /// Tasks WebKit stopped while their file was still being read; they must
    /// not be answered.
    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            let path = Self.filePath(for: url),
            Self.servedExtensions.contains((path as NSString).pathExtension.lowercased())
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // Read off the main thread: a README with many large images would
        // otherwise stall the UI while the page loads.
        nonisolated(unsafe) let task = urlSchemeTask
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            DispatchQueue.main.async {
                guard self.stoppedTasks.remove(ObjectIdentifier(task)) == nil else { return }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime ?? "application/octet-stream", "Content-Length": "\(data.count)"
                    ])
                if let response { task.didReceive(response) }
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }
}
