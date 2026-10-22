import SwiftUI
import WebKit

/// Shown in place of the web view when a page fails to load, so a dead
/// server or typo reads as a themed message instead of a blank (white) page.
struct BrowserErrorView: View {
    let url: URL
    let error: Error
    let onRetry: () -> Void
    @Environment(\.tokens) private var t

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: Self.symbol(for: error))
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(t.textTertiary)
            Text(Self.title(for: error))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.text)
            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(t.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if url.absoluteString != "about:blank" {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(t.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            Button("Try Again", action: onRetry)
                .buttonStyle(.themedProminent)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.termBg)
    }

    private static let tlsErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
        NSURLErrorServerCertificateHasUnknownRoot
    ]

    static func title(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "Can't open this page" }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "You're offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Server not found"
        case NSURLErrorCannotConnectToHost: return "Can't connect to the server"
        case NSURLErrorTimedOut: return "The server took too long to respond"
        case let code where tlsErrorCodes.contains(code): return "Secure connection failed"
        case NSURLErrorFileDoesNotExist: return "File not found"
        default: return "Can't open this page"
        }
    }

    static func symbol(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "exclamationmark.triangle" }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "wifi.slash"
        case let code where tlsErrorCodes.contains(code): return "lock.slash"
        default: return "exclamationmark.triangle"
        }
    }

    /// Failures that are not page errors: a cancelled load (new navigation,
    /// stop button) or a response turned into a download.
    static func isSilent(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        // WebKitErrorFrameLoadInterruptedByPolicyChange (102): the navigation became a download.
        // 204: plug-in handled the load.
        if nsError.domain == WKErrorDomain || nsError.domain == "WebKitErrorDomain" {
            return nsError.code == 102 || nsError.code == 204
        }
        return false
    }
}
