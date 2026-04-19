import AppKit
import SwiftUI

@MainActor
final class WindowBridgeModel {
    static let shared = WindowBridgeModel()
    private init() {}

    private(set) var windowController: MainWindowController?

    func boot(window: NSWindow) {
        guard windowController == nil else { return }
        windowController = MainWindowController(swiftUIWindow: window)
    }
}

final class WindowReaderView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        onWindow?(w)
        onWindow = nil
    }
}

struct WindowBridgeRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowReaderView {
        let v = WindowReaderView()
        v.onWindow = { WindowBridgeModel.shared.boot(window: $0) }
        return v
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}
}

public struct WindowBridgeView: View {
    public init() {}

    public var body: some View {
        WindowBridgeRepresentable()
            .frame(width: 0, height: 0)
    }
}
