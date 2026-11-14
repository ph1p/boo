import XCTest

@testable import Boo

final class ProfileFileTests: XCTestCase {
    func testParsesAndReportsBadEntries() throws {
        let json = """
            {"profiles": [
              {"name": " Prod ", "theme": "Dracula", "fontSize": 14, "linkTarget": "external"},
              {"name": ""},
              {"name": "Prod"},
              {"name": "Huge", "fontSize": 900}
            ]}
            """
        let (profiles, problems) = try ProfileFile.parse(Data(json.utf8))
        XCTAssertEqual(profiles.map(\.name), ["Prod"])
        XCTAssertEqual(profiles.first?.linkTarget, .external)
        XCTAssertEqual(problems.count, 3)
    }

    func testSurfaceStyleDefault() {
        XCTAssertTrue(SurfaceStyle(profile: Profile(name: "a", shell: "zsh"), workspace: nil).isDefault)
        XCTAssertFalse(SurfaceStyle(profile: Profile(name: "a", shader: ""), workspace: nil).isDefault)
        XCTAssertTrue(SurfaceStyle(profile: nil, workspace: WorkspaceSettings(defaultProfile: "a")).isDefault)
    }

    func testSurfaceStylePrefersProfileOverWorkspace() {
        let workspace = WorkspaceSettings(
            themeName: "Boo Dark", lightThemeName: "Boo Light", fontName: "Menlo", fontSize: 16)
        let inherited = SurfaceStyle(profile: nil, workspace: workspace)
        XCTAssertEqual(inherited.themeName(lightAppearance: false), "Boo Dark")
        XCTAssertEqual(inherited.themeName(lightAppearance: true), "Boo Light")
        XCTAssertEqual(inherited.fontFamily, "Menlo")
        XCTAssertEqual(inherited.fontSize, 16)

        // A profile's theme is fixed, so the workspace's light theme no longer applies.
        let profiled = SurfaceStyle(profile: Profile(name: "p", theme: "Nord", fontSize: 20), workspace: workspace)
        XCTAssertEqual(profiled.themeName(lightAppearance: true), "Nord")
        XCTAssertEqual(profiled.fontFamily, "Menlo")
        XCTAssertEqual(profiled.fontSize, 20)

        let lightOnly = SurfaceStyle(profile: nil, workspace: WorkspaceSettings(lightThemeName: "Boo Light"))
        XCTAssertNil(lightOnly.themeName(lightAppearance: false))
        XCTAssertEqual(lightOnly.themeName(lightAppearance: true), "Boo Light")
    }

    func testSurfaceStyleKeysDiffer() {
        let a = SurfaceStyle(profile: Profile(name: "a", theme: "Nord"), workspace: nil)
        let b = SurfaceStyle(profile: Profile(name: "b", fontFamily: "Nord"), workspace: nil)
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
        // Two profiles with the same look share one config.
        XCTAssertEqual(a, SurfaceStyle(profile: Profile(name: "c", theme: "Nord", shell: "zsh"), workspace: nil))
        XCTAssertTrue(
            WorkspaceSettings(defaultProfile: "x").sameSurfaceLook(as: WorkspaceSettings(sidebarPosition: 0)))
        XCTAssertFalse(WorkspaceSettings(fontSize: 12).sameSurfaceLook(as: WorkspaceSettings()))
    }

    func testLaunchSpecMerging() {
        let profile = Profile(name: "p", shell: "/bin/zsh", env: ["A": "1", "B": "1"], cwd: "~/x")
        let spec = profile.launchSpec(merging: LaunchSpec(cwd: "/own", env: ["B": "2"]))
        XCTAssertEqual(spec?.cwd, "/own")
        XCTAssertEqual(spec?.program, "/bin/zsh")
        XCTAssertEqual(spec?.env, ["A": "1", "B": "2"])
        XCTAssertEqual(profile.launchSpec(merging: nil)?.cwd, NSHomeDirectory() + "/x")
        XCTAssertNil(Profile(name: "q", theme: "x").launchSpec(merging: nil))
    }
}

final class LinkResolverTests: XCTestCase {
    private func kinds(_ line: String) -> [TerminalLink.Kind] {
        LinkResolver.links(in: line).map(\.kind)
    }

    func testFileLineColumn() {
        XCTAssertEqual(kinds("src/main.swift:12:4: error"), [.file(path: "src/main.swift", line: 12, column: 4)])
        XCTAssertEqual(kinds("at app.ts(3,9)"), [.file(path: "app.ts", line: 3, column: 9)])
        XCTAssertEqual(kinds(#"  File "/x/y.py", line 7, in f"#), [.file(path: "/x/y.py", line: 7, column: nil)])
    }

    func testURLsWinOverPaths() {
        let k = kinds("see https://example.com/a/b.html, then ./c.txt.")
        XCTAssertEqual(k.count, 2)
        XCTAssertEqual(k.first, .url(URL(string: "https://example.com/a/b.html")!))
        XCTAssertEqual(k.last, .file(path: "./c.txt", line: nil, column: nil))
    }

    func testNotPaths() {
        XCTAssertTrue(kinds("at 12:30:45 version 1.2.3").isEmpty)
    }

    func testRangesAreCharacterOffsets() {
        let line = "é → src/a.go:3"
        let link = LinkResolver.links(in: line).first
        XCTAssertEqual(link?.range, 4..<14)
        XCTAssertNotNil(LinkResolver.link(in: line, at: 6))
        XCTAssertNil(LinkResolver.link(in: line, at: 1))
    }

    func testColumnToCharacterIndexCountsWideCells() {
        XCTAssertEqual(LinkResolver.characterIndex(forColumn: 0, in: "日本x"), 0)
        XCTAssertEqual(LinkResolver.characterIndex(forColumn: 1, in: "日本x"), 0)
        XCTAssertEqual(LinkResolver.characterIndex(forColumn: 4, in: "日本x"), 2)
        XCTAssertNil(LinkResolver.characterIndex(forColumn: 5, in: "日本x"))
    }

    func testResolveAndGitPrefixes() {
        XCTAssertEqual(LinkResolver.resolve("b/../c", cwd: "/r"), "/r/c")
        XCTAssertEqual(LinkResolver.candidates("a/src/x", cwd: "/r"), ["/r/a/src/x", "/r/src/x"])
    }

    func testExpandTemplate() {
        XCTAssertEqual(
            LinkResolver.expandTemplate("vscode://file{path}:{line}:{col}", path: "/a b/c", line: 3, column: nil),
            "vscode://file/a%20b/c:3:1")
        XCTAssertEqual(
            LinkResolver.expandTemplate("subl {path}:{line}", path: "/it's", line: nil, column: nil),
            #"subl '/it'\''s':1"#)
    }
}

final class ShaderLibraryTests: XCTestCase {
    func testPresetsAreBundled() {
        for preset in ShaderLibrary.presets {
            let path = ShaderLibrary.path(for: preset)
            XCTAssertNotNil(path, preset)
            XCTAssertTrue(path.map { FileManager.default.fileExists(atPath: $0) } ?? false, preset)
        }
    }

    func testEmptyAndMissing() {
        XCTAssertNil(ShaderLibrary.path(for: "  "))
        XCTAssertNil(ShaderLibrary.path(for: "/nope/missing.glsl"))
    }
}
