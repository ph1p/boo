import Foundation

/// One failed assertion or test from a test run's output.
struct TestFailure: Equatable, Sendable {
    /// "Suite.test", "suite › test", "tests/test_x.py::test_y"…
    var name: String
    /// As printed: absolute or relative to where the tests ran.
    var file: String?
    var line: Int?
    /// The failure message, at most a few lines.
    var message: String

    /// "File.swift:12", or nil without a file.
    var location: String? {
        guard let file else { return nil }
        return line.map { "\(file):\($0)" } ?? file
    }
}

/// The failures found in one command's output.
struct TestFailureReport: Equatable, Sendable {
    var framework: String
    var failures: [TestFailure]

    /// Distinct failed tests (one test can fail several assertions).
    var testCount: Int { Set(failures.map(\.name)).count }

    var summary: String { testCount == 1 ? "1 test failed" : "\(testCount) tests failed" }
}

/// Finds failed tests in the output of XCTest / swift-testing, Jest, Vitest,
/// pytest, cargo test and go test.
enum TestFailureParser {
    static let messageLines = 6

    static func parse(_ output: String) -> TestFailureReport? {
        let lines = stripANSI(output).components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        let parsers: [(String, ([String]) -> [TestFailure])] = [
            ("XCTest", xctest), ("Vitest", vitest), ("Jest", jest), ("pytest", pytest), ("cargo test", cargo),
            ("go test", goTest)
        ]
        for (framework, parser) in parsers {
            let failures = unique(parser(lines))
            if !failures.isEmpty { return TestFailureReport(framework: framework, failures: failures) }
        }
        return nil
    }

    // MARK: - XCTest / swift-testing

    private static let xctestLine = regex(#"^(.+?\.swift):(\d+): error: -?\[?([\w.]+)[ .](\w+)\]? : (.*)$"#)
    private static let swiftTestingLine = regex(
        #"^\S+ Test (\S+?(?:\(\))?|"[^"]*") recorded an issue at (.+?\.swift):(\d+):\d+: (.*)$"#)

    static func xctest(_ lines: [String]) -> [TestFailure] {
        lines.compactMap { line in
            if let m = match(xctestLine, line) {
                let suite = m[3].split(separator: ".").last.map(String.init) ?? m[3]
                return TestFailure(name: "\(suite).\(m[4])", file: m[1], line: Int(m[2]), message: m[5])
            }
            if let m = match(swiftTestingLine, line) {
                return TestFailure(
                    name: m[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")), file: m[2], line: Int(m[3]),
                    message: m[4])
            }
            return nil
        }
    }

    // MARK: - Vitest

    private static let vitestHeader = regex(#"^\s*FAIL\s+(\S+)\s+>\s+(.+?)\s*$"#)
    private static let vitestLocation = regex(#"^\s*❯\s+(\S+?):(\d+):\d+"#)

    static func vitest(_ lines: [String]) -> [TestFailure] {
        sections(lines, header: vitestHeader).map { header, body in
            let location = body.lazy.compactMap { match(vitestLocation, $0) }.first
            return TestFailure(
                name: header[2].replacingOccurrences(of: " > ", with: " › "),
                file: location?[1] ?? header[1], line: location.flatMap { Int($0[2]) },
                message: message(body.prefix { match(vitestLocation, $0) == nil }))
        }
    }

    // MARK: - Jest

    private static let jestHeader = regex(#"^\s*● (.+?)\s*$"#)
    private static let jestStack = regex(#"^\s*at .*?\(?([^\s()]+?):(\d+):\d+\)?$"#)
    private static let jestFile = regex(#"^\s*FAIL\s+(\S+)\s*$"#)

    static func jest(_ lines: [String]) -> [TestFailure] {
        var file: String?
        var failures: [TestFailure] = []
        var current: (name: String, body: [String])?
        func flush() {
            guard let (name, body) = current else { return }
            current = nil
            if name == "Test suite failed to run" && body.isEmpty { return }
            let frame = body.lazy.compactMap { match(jestStack, $0) }.first { !$0[1].contains("node_modules") }
            failures.append(
                TestFailure(
                    name: name, file: frame?[1] ?? file, line: frame.flatMap { Int($0[2]) },
                    message: message(body.prefix { match(jestStack, $0) == nil })))
        }
        for line in lines {
            if let m = match(jestFile, line) {
                flush()
                file = m[1]
            } else if let m = match(jestHeader, line) {
                flush()
                current = (m[1], [])
            } else if line.hasPrefix("Test Suites:") || line.hasPrefix("Tests:") {
                flush()
            } else {
                current?.body.append(line)
            }
        }
        flush()
        return failures
    }

    // MARK: - pytest

    private static let pytestSummary = regex(#"^(?:FAILED|ERROR) (\S+?)(?: - (.*))?$"#)
    private static let pytestSection = regex(#"^_{3,} (.+?) _{3,}$"#)
    private static let pytestLocation = regex(#"^(\S+\.py):(\d+): \w"#)

    static func pytest(_ lines: [String]) -> [TestFailure] {
        // Each "____ test_name ____" section ends with "file.py:12: Error".
        var locations: [String: (String, Int)] = [:]
        var section: String?
        for line in lines {
            if let m = match(pytestSection, line) {
                section = m[1]
            } else if let section, let m = match(pytestLocation, line), let number = Int(m[2]) {
                locations[section] = (m[1], number)
            }
        }
        return lines.compactMap { line in
            guard let m = match(pytestSummary, line) else { return nil }
            let id = m[1]
            let parts = id.components(separatedBy: "::")
            let key = parts.dropFirst().joined(separator: ".")
            let location = locations[key] ?? locations[parts.last ?? ""]
            return TestFailure(
                name: id, file: location?.0 ?? parts.first, line: location?.1, message: m[2])
        }
    }

    // MARK: - cargo test

    private static let cargoHeader = regex(#"^---- (\S+) stdout ----$"#)
    private static let cargoPanic = regex(#"panicked at (?:'(.*)', )?([^\s:]+):(\d+):\d+:?$"#)

    static func cargo(_ lines: [String]) -> [TestFailure] {
        sections(lines, header: cargoHeader).map { header, body in
            guard let index = body.firstIndex(where: { match(cargoPanic, $0) != nil }),
                let panic = match(cargoPanic, body[index])
            else { return TestFailure(name: header[1], message: message(body[...])) }
            let text = panic[1].isEmpty ? message(body[(index + 1)...].prefix { !$0.hasPrefix("note:") }) : panic[1]
            return TestFailure(name: header[1], file: panic[2], line: Int(panic[3]), message: text)
        }
    }

    // MARK: - go test

    private static let goHeader = regex(#"^\s*--- FAIL: (\S+)"#)
    private static let goLocation = regex(#"^\s+(\S+_test\.go):(\d+): (.*)$"#)

    static func goTest(_ lines: [String]) -> [TestFailure] {
        var failures: [TestFailure] = []
        for (index, line) in lines.enumerated() {
            guard let header = match(goHeader, line) else { continue }
            let body = lines[(index + 1)...].prefix { match(goHeader, $0) == nil && !$0.hasPrefix("FAIL") }
            let location = body.lazy.compactMap { match(goLocation, $0) }.first
            failures.append(
                TestFailure(
                    name: header[1], file: location?[1], line: location.flatMap { Int($0[2]) },
                    message: location?[3] ?? ""))
        }
        return failures
    }

    // MARK: - Helpers

    /// Each header match with the lines up to the next header.
    private static func sections(_ lines: [String], header: NSRegularExpression) -> [([String], [String])] {
        var result: [([String], [String])] = []
        for (index, line) in lines.enumerated() {
            guard let m = match(header, line) else { continue }
            let body = lines[(index + 1)...].prefix { match(header, $0) == nil }
            result.append((m, Array(body)))
        }
        return result
    }

    /// The first few non-empty lines, de-indented.
    private static func message<S: Sequence>(_ lines: S) -> String where S.Element == String {
        let trimmed = lines.map { (line: String) -> String in line.trimmingCharacters(in: .whitespaces) }
        let kept = trimmed.filter { line in !line.isEmpty && !line.allSatisfy { "⎯-─=".contains($0) } }
        return kept.prefix(messageLines).joined(separator: "\n")
    }

    private static func unique(_ failures: [TestFailure]) -> [TestFailure] {
        var seen = Set<String>()
        return failures.filter { seen.insert("\($0.name)\u{0}\($0.location ?? "")\u{0}\($0.message)").inserted }
    }

    private static let ansi = regex(#"\u001B\[[0-9;?]*[ -/]*[@-~]"#)

    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return ansi.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of a whole-line match; unmatched groups are "".
    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { index in
            Range(m.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
