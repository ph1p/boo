import Boo
import SwiftUI

@main
struct BooSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            WindowBridgeView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)

    }
}
