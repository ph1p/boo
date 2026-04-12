import XCTest

@testable import Boo

final class ContentStateTests: XCTestCase {
    // MARK: - Terminal State

    func testTerminalStateInit() {
        let state = TerminalContentState(
            title: "zsh",
            workingDirectory: "/Users/test",
            shellPID: 1234
        )
        XCTAssertEqual(state.contentType, .terminal)
        XCTAssertEqual(state.title, "zsh")
        XCTAssertEqual(state.workingDirectory, "/Users/test")
        XCTAssertEqual(state.shellPID, 1234)
    }

    func testTerminalStateDefaults() {
        let state = TerminalContentState()
        XCTAssertEqual(state.title, "")
        XCTAssertEqual(state.workingDirectory, "~")
        XCTAssertEqual(state.shellPID, 0)
        XCTAssertEqual(state.foregroundProcess, "")
    }

    // MARK: - Browser State

    func testBrowserStateInit() {
        let url = URL(string: "https://example.com")!
        let state = BrowserContentState(title: "Example", url: url, canGoBack: true)
        XCTAssertEqual(state.contentType, .browser)
        XCTAssertEqual(state.title, "Example")
        XCTAssertEqual(state.url, url)
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
    }

    func testBrowserStateDefaults() {
        let state = BrowserContentState()
        XCTAssertEqual(state.title, "New Tab")
        XCTAssertEqual(state.url.absoluteString, "about:blank")
    }

    // MARK: - Editor State

    func testEditorStateInit() {
        let state = EditorContentState(
            title: "file.swift",
            filePath: "/path/to/file.swift",
            isDirty: true
        )
        XCTAssertEqual(state.contentType, .editor)
        XCTAssertEqual(state.title, "file.swift")
        XCTAssertEqual(state.filePath, "/path/to/file.swift")
        XCTAssertTrue(state.isDirty)
    }

    // MARK: - Image Viewer State

    func testImageViewerStateInit() {
        let state = ImageViewerContentState(
            title: "photo.png",
            filePath: "/path/to/photo.png",
            zoom: 2.0
        )
        XCTAssertEqual(state.contentType, .imageViewer)
        XCTAssertEqual(state.title, "photo.png")
        XCTAssertEqual(state.filePath, "/path/to/photo.png")
        XCTAssertEqual(state.zoom, 2.0)
    }

    // MARK: - Markdown Preview State

    func testMarkdownPreviewStateInit() {
        let state = MarkdownPreviewContentState(
            title: "README.md",
            filePath: "/path/to/README.md",
            scrollPosition: 100
        )
        XCTAssertEqual(state.contentType, .markdownPreview)
        XCTAssertEqual(state.title, "README.md")
        XCTAssertEqual(state.filePath, "/path/to/README.md")
        XCTAssertEqual(state.scrollPosition, 100)
    }

    // MARK: - ContentState Enum

    func testContentStateContentType() {
        XCTAssertEqual(ContentState.terminal(TerminalContentState()).contentType, .terminal)
        XCTAssertEqual(ContentState.browser(BrowserContentState()).contentType, .browser)
        XCTAssertEqual(ContentState.editor(EditorContentState()).contentType, .editor)
        XCTAssertEqual(
            ContentState.imageViewer(ImageViewerContentState(title: "", filePath: "")).contentType,
            .imageViewer
        )
        XCTAssertEqual(
            ContentState.markdownPreview(MarkdownPreviewContentState(title: "", filePath: "")).contentType,
            .markdownPreview
        )
    }

    func testContentStateTitleGetSet() {
        var state = ContentState.terminal(TerminalContentState(title: "original"))
        XCTAssertEqual(state.title, "original")

        state.title = "updated"
        XCTAssertEqual(state.title, "updated")
    }

    func testContentStateAsTerminal() {
        let terminalState = TerminalContentState(title: "zsh", workingDirectory: "/tmp")
        let state = ContentState.terminal(terminalState)

        XCTAssertNotNil(state.asTerminal)
        XCTAssertEqual(state.asTerminal?.workingDirectory, "/tmp")

        let browserState = ContentState.browser(BrowserContentState())
        XCTAssertNil(browserState.asTerminal)
    }

    func testContentStateUpdateTerminal() {
        var state = ContentState.terminal(TerminalContentState(workingDirectory: "/original"))

        state.updateTerminal { s in
            s.workingDirectory = "/updated"
        }

        XCTAssertEqual(state.asTerminal?.workingDirectory, "/updated")
    }

    func testContentStateUpdateTerminalNoOpForNonTerminal() {
        var state = ContentState.browser(BrowserContentState(title: "Browser"))

        state.updateTerminal { s in
            s.workingDirectory = "/should-not-change"
        }

        // Should remain browser state
        XCTAssertEqual(state.contentType, .browser)
        XCTAssertEqual(state.title, "Browser")
    }

    // MARK: - Codable

    func testContentStateCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let states: [ContentState] = [
            .terminal(TerminalContentState(title: "zsh", workingDirectory: "/tmp")),
            .browser(BrowserContentState(title: "Google", url: URL(string: "https://google.com")!)),
            .editor(EditorContentState(title: "file.swift")),
            .imageViewer(ImageViewerContentState(title: "photo.png", filePath: "/path/photo.png")),
            .markdownPreview(MarkdownPreviewContentState(title: "README.md", filePath: "/path/README.md"))
        ]

        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ContentState.self, from: data)
            XCTAssertEqual(decoded.contentType, state.contentType)
            XCTAssertEqual(decoded.title, state.title)
        }
    }
}
