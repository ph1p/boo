import Cocoa
import XCTest

@testable import Boo

@MainActor
final class CommandPaletteTests: XCTestCase {
    private func item(
        _ kind: PaletteItem.Kind, _ title: String, enabled: Bool = true, ran: (() -> Void)? = nil
    )
        -> PaletteItem
    {
        PaletteItem(id: "\(kind):\(title)", kind: kind, title: title, isEnabled: enabled, perform: { ran?() })
    }

    func testFuzzyMatcherRejectsNonSubsequence() {
        XCTAssertNil(FuzzyMatcher.score("xyz", "Split Right"))
        XCTAssertNil(FuzzyMatcher.score("rs", "Split Right"))
        XCTAssertEqual(FuzzyMatcher.score("", "anything"), 0)
        XCTAssertNotNil(FuzzyMatcher.score("SR", "split right"))
    }

    func testFuzzyMatcherPrefersWordStartsAndRuns() {
        let wordStarts = FuzzyMatcher.score("sr", "Split Right")!
        let scattered = FuzzyMatcher.score("sr", "Close Other Tabs Right")!
        XCTAssertGreaterThan(wordStarts, scattered)

        let run = FuzzyMatcher.score("split", "Split Right")!
        let gappy = FuzzyMatcher.score("split", "Select Pane Left In Tab")!
        XCTAssertGreaterThan(run, gappy)

        // Same match, shorter text wins.
        XCTAssertGreaterThan(
            FuzzyMatcher.score("split right", "Split Right")!,
            FuzzyMatcher.score("split right", "Split Right and Focus")!)
    }

    func testRankOrdersItemsAndGroupsByScore() {
        let items = [
            item(.action, "Close Other Tabs Right"), item(.action, "Split Right"), item(.workspace, "boo"),
            item(.theme, "Nord")
        ]
        let groups = PaletteRanker.rank(items, query: PaletteQuery("sr"), recents: [])
        XCTAssertEqual(groups.map(\.kind), [.action])
        XCTAssertEqual(groups[0].items.map(\.title), ["Split Right", "Close Other Tabs Right"])

        let solar = PaletteRanker.rank(items, query: PaletteQuery("nord"), recents: [])
        XCTAssertEqual(solar.first?.kind, .theme)
    }

    func testEmptyQueryKeepsKindOrderAndRecentsFirst() {
        let items = [item(.theme, "Nord"), item(.action, "A"), item(.action, "B"), item(.workspace, "boo")]
        let groups = PaletteRanker.rank(items, query: PaletteQuery(""), recents: ["action:B"])
        XCTAssertEqual(groups.map(\.kind), [.action, .workspace, .theme])
        XCTAssertEqual(groups[0].items.map(\.title), ["B", "A"])
    }

    func testRecencyBreaksCloseScores() {
        let items = [item(.action, "New Tab"), item(.action, "New Window")]
        XCTAssertEqual(
            PaletteRanker.rank(items, query: PaletteQuery("new"), recents: []).first?.items.first?.title, "New Tab")
        XCTAssertEqual(
            PaletteRanker.rank(items, query: PaletteQuery("new"), recents: ["action:New Window"])
                .first?.items.first?.title, "New Window")
    }

    func testPrefixFiltersKind() {
        XCTAssertEqual(PaletteQuery("> split"), PaletteQuery(kind: .action, text: "split"))
        XCTAssertEqual(PaletteQuery("@boo").kind, .workspace)
        XCTAssertEqual(PaletteQuery("#vim").kind, .tab)
        XCTAssertEqual(PaletteQuery(":nord").kind, .theme)
        XCTAssertNil(PaletteQuery("split").kind)

        let items = [item(.action, "Nord Action"), item(.theme, "Nord")]
        let groups = PaletteRanker.rank(items, query: PaletteQuery(":nord"), recents: [])
        XCTAssertEqual(groups.map(\.kind), [.theme])
    }

    func testSSHPrefixSelectsHosts() {
        XCTAssertEqual(PaletteQuery("@ssh web"), PaletteQuery(kind: .host, text: "web"))
        XCTAssertEqual(PaletteQuery("@ssh"), PaletteQuery(kind: .host, text: ""))
        XCTAssertEqual(PaletteQuery("@sshd"), PaletteQuery(kind: .workspace, text: "sshd"))
    }

    func testHistoryOnlyWithBangPrefix() {
        XCTAssertEqual(PaletteQuery("! git"), PaletteQuery(kind: .history, text: "git"))
        let items = [item(.action, "Git Pull"), item(.history, "git pull --rebase")]
        XCTAssertEqual(PaletteRanker.rank(items, query: PaletteQuery("git"), recents: []).map(\.kind), [.action])
        XCTAssertEqual(PaletteRanker.rank(items, query: PaletteQuery("!git"), recents: []).map(\.kind), [.history])
    }

    func testRecordingMovesToFrontAndCaps() {
        let full = (0..<PaletteRanker.recentLimit).map { "id\($0)" }
        let recorded = PaletteRanker.recording("id7", in: full)
        XCTAssertEqual(recorded.first, "id7")
        XCTAssertEqual(recorded.count, PaletteRanker.recentLimit)
        XCTAssertEqual(recorded.filter { $0 == "id7" }.count, 1)
        XCTAssertEqual(PaletteRanker.recording("new", in: full).count, PaletteRanker.recentLimit)
    }

    func testDisabledActionShownDimmedAndNotRun() {
        final class Target: NSObject, NSMenuItemValidation {
            var ran = 0
            @objc func off(_ sender: Any?) { ran += 1 }
            func validateMenuItem(_ item: NSMenuItem) -> Bool { false }
        }
        let target = Target()
        let main = NSMenu()
        let top = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Terminal")
        let off = NSMenuItem(title: "Off", action: #selector(Target.off(_:)), keyEquivalent: "")
        off.target = target
        menu.addItem(off)
        top.submenu = menu
        main.addItem(top)

        let actions = PaletteSources.actions(menu: main)
        XCTAssertEqual(actions.map(\.id), ["action:Terminal/Off"])
        XCTAssertFalse(actions[0].isEnabled)
        // Still listed when searched for.
        XCTAssertEqual(PaletteRanker.rank(actions, query: PaletteQuery("off"), recents: []).first?.items.count, 1)

        let model = CommandPaletteModel()
        model.load(items: actions, recents: [])
        var accepted: [Int] = []
        model.onAccept = { accepted.append($0) }
        model.accept(0)
        XCTAssertEqual(accepted, [0])
        actions[0].perform()
        XCTAssertEqual(target.ran, 0)
    }

    func testModelSelectionWraps() {
        let model = CommandPaletteModel()
        model.load(items: [item(.action, "A"), item(.action, "B"), item(.workspace, "C")], recents: [])
        XCTAssertEqual(model.selection, 0)
        model.move(-1)
        XCTAssertEqual(model.item(at: model.selection)?.title, "C")
        model.move(1)
        XCTAssertEqual(model.selection, 0)
        model.query = "b"
        XCTAssertEqual(model.flatItems.map(\.title), ["B"])
        XCTAssertEqual(model.selection, 0)
    }
}
