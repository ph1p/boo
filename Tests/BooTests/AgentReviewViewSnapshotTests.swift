import AppKit
import SwiftUI
import XCTest

@testable import Boo

/// Renders the diff tab for a small repo, unified and side by side. Set
/// `BOO_SNAPSHOT_DIR` to write `review-unified.png` and `review-split.png` there.
@MainActor
final class AgentReviewViewSnapshotTests: XCTestCase {
    func testRendersModifiedAndAddedFiles() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let repo = (base as NSString).appendingPathComponent("boo-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try AgentWorktree.git(
                ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false"] + args, in: repo)
        }
        func write(_ file: String, _ text: String) throws {
            try text.write(toFile: (repo as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let body = (1...30).map { "    let value\($0) = compute(\($0))\n" }.joined()
        try git("init", "-q", "-b", "main")
        try write("Sources.swift", "struct Box {\n    func run() {\n" + body + "    }\n}\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try write(
            "Sources.swift",
            "struct Box {\n    func run() {\n"
                + body.replacingOccurrences(of: "compute(12)", with: "compute(12, fast: true)")
                .replacingOccurrences(of: "    let value20 = compute(20)\n", with: "") + "    }\n}\n")
        try write("Added.swift", "import Foundation\n\nenum Added {\n    static let answer = 42\n}\n")

        for layout in [DiffLayout.unified, .split] {
            let model = AgentReviewModel(
                workspaceID: UUID(), folder: repo,
                selectedPath: ProcessInfo.processInfo.environment["BOO_SNAPSHOT_FILE"] ?? "Sources.swift")
            model.layout = layout
            model.wrap = false
            model.reload()
            let loaded = expectation(description: "changes")
            func poll() {
                if model.changes != nil { loaded.fulfill() } else { DispatchQueue.main.async { poll() } }
            }
            poll()
            wait(for: [loaded], timeout: 10)
            XCTAssertEqual(model.changes?.files.map(\.path), ["Sources.swift", "Added.swift"])

            let host = NSHostingView(rootView: AgentReviewView(model: model).frame(width: 900, height: 420))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["BOO_SNAPSHOT_DIR"],
                let png = rep.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("review-\(layout).png"))
            }
        }
    }
}
