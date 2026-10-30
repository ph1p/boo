import XCTest

@testable import Boo

@MainActor
final class WelcomeWindowTests: XCTestCase {
    func testWelcomeTipsNameRealMenuItems() {
        let controller = MainWindowController()
        controller.setupMenuItems()
        for tip in WelcomeView.tips {
            XCTAssertNotNil(ActionRegistry.action(id: tip.id)?.shortcut, tip.id)
        }
        for name in WelcomeView.starterThemes {
            XCTAssertNotNil(AppSettings.shared.theme(named: name), name)
        }
    }
}
