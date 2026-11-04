import XCTest

@testable import Boo

final class LinkTargetTests: XCTestCase {
    func testLegacyMonacoValueDecodesAsEditor() throws {
        XCTAssertEqual(LinkTarget(rawValue: "monaco"), .editor)
        let decoded = try JSONDecoder().decode([LinkTarget].self, from: Data(#"["monaco","editor","external"]"#.utf8))
        XCTAssertEqual(decoded, [.editor, .editor, .external])
        XCTAssertNil(LinkTarget(rawValue: "vim"))
        XCTAssertEqual(LinkTarget.editor.rawValue, "editor")
    }
}
