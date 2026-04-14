import SwiftUI
import XCTest

@testable import Boo

final class SidebarStateResolverTests: XCTestCase {
    private func makeEnvironment(
        usesPerWorkspaceState: Bool = false,
        position: SidebarPosition = .right,
        splitViewWidth: CGFloat? = 1_000,
        dividerThickness: CGFloat = 1,
        backingScaleFactor: CGFloat = 2
    ) -> SidebarStateEnvironment {
        SidebarStateEnvironment(
            defaultState: SidebarWorkspaceState(isVisible: true, width: 250),
            usesPerWorkspaceState: usesPerWorkspaceState,
            position: position,
            splitViewWidth: splitViewWidth,
            dividerThickness: dividerThickness,
            backingScaleFactor: backingScaleFactor
        )
    }

    func testEffectiveStateUsesWorkspaceOverridesWhenPerWorkspaceEnabled() {
        let workspaceState = SidebarWorkspaceState(isVisible: false, width: 312)
        let resolvedState = SidebarStateResolver.effectiveState(
            workspaceState: workspaceState,
            environment: makeEnvironment(usesPerWorkspaceState: true)
        )

        XCTAssertEqual(resolvedState.isVisible, false)
        XCTAssertEqual(resolvedState.width ?? -1, 312, accuracy: 0.001)
    }

    func testEffectiveStateIgnoresWorkspaceOverridesWhenPerWorkspaceDisabled() {
        let workspaceState = SidebarWorkspaceState(isVisible: false, width: 312)
        let resolvedState = SidebarStateResolver.effectiveState(
            workspaceState: workspaceState,
            environment: makeEnvironment(usesPerWorkspaceState: false)
        )

        XCTAssertEqual(resolvedState.isVisible, true)
        XCTAssertEqual(resolvedState.width ?? -1, 250, accuracy: 0.001)
    }

    func testPersistenceTargetMatchesPerWorkspaceFlag() {
        XCTAssertEqual(
            SidebarStateResolver.persistenceTarget(usesPerWorkspaceState: true),
            .workspace
        )
        XCTAssertEqual(
            SidebarStateResolver.persistenceTarget(usesPerWorkspaceState: false),
            .appSettings
        )
    }

    func testNormalizedWidthSnapsOnceWithoutDrift() {
        let environment = makeEnvironment()
        let requestedWidth: CGFloat = 287.3
        let first = SidebarStateResolver.normalizedWidth(requestedWidth, environment: environment)
        let second = SidebarStateResolver.normalizedWidth(first, environment: environment)

        XCTAssertEqual(first, 287.5, accuracy: 0.001)
        XCTAssertEqual(second, first, accuracy: 0.001)
    }

    func testRenderedStateClampsForNarrowWindowWithoutChangingStoredWidth() {
        let storedState = SidebarWorkspaceState(isVisible: true, width: 480)
        let renderedState = SidebarStateResolver.renderedState(
            from: storedState,
            environment: makeEnvironment(splitViewWidth: 420)
        )

        XCTAssertEqual(storedState.width ?? -1, 480, accuracy: 0.001)
        XCTAssertEqual(renderedState.width ?? -1, 140, accuracy: 0.001)
    }

    func testRightSidebarNormalizationAccountsForDividerThickness() {
        let environment = makeEnvironment(position: .right, splitViewWidth: 1_000, dividerThickness: 6)
        let normalizedWidth = SidebarStateResolver.normalizedWidth(900, environment: environment)

        XCTAssertEqual(normalizedWidth, 694, accuracy: 0.001)
    }

    func testRightSidebarDividerPositionSnapsToDevicePixels() {
        let environment = makeEnvironment(
            position: .right,
            splitViewWidth: 1_001.2,
            dividerThickness: 1,
            backingScaleFactor: 2
        )

        let dividerPosition = SidebarStateResolver.dividerPosition(
            forSidebarWidth: 246,
            environment: environment
        )

        XCTAssertEqual(dividerPosition, 754, accuracy: 0.001)
    }

    func testLayoutSettingsBindingReadsFreshValuesAndWritesBack() {
        let original = AppSettings.shared.sidebarPerWorkspaceState
        defer { AppSettings.shared.sidebarPerWorkspaceState = original }

        let binding = LayoutSettingsBindings.binding(\.sidebarPerWorkspaceState)
        AppSettings.shared.sidebarPerWorkspaceState = false
        XCTAssertFalse(binding.wrappedValue)

        AppSettings.shared.sidebarPerWorkspaceState = true
        XCTAssertTrue(binding.wrappedValue)

        binding.wrappedValue = false
        XCTAssertFalse(AppSettings.shared.sidebarPerWorkspaceState)
    }
}
