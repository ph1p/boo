import XCTest

@testable import Boo

final class SSHConfigParserTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    private func write(_ name: String, _ text: String) -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func parse(_ text: String) -> SSHConfig {
        SSHConfigParser.parse(path: write("config", text), sshDir: dir)
    }

    func testHostBlocksAndFirstValueWins() {
        let config = parse(
            """
            Host web
              HostName 10.0.0.1
              User deploy
              Port 2222
              User other

            Host db db2
                hostname=db.internal
            """)
        XCTAssertEqual(config.hosts.map(\.alias), ["web", "db", "db2"])
        XCTAssertEqual(config.hosts[0].address, "deploy@10.0.0.1:2222")
        XCTAssertEqual(config.hosts[0].line, 1)
        XCTAssertEqual(config.hosts[1].hostName, "db.internal")
        XCTAssertEqual(config.hosts[2].line, 7)
        XCTAssertEqual(config.hosts[2].address, "db.internal")
    }

    func testSkipsWildcardsNegationsAndMatch() {
        let config = parse(
            """
            Host *
              User root
            Host *.corp !bastion jump
              User me
            Match host foo
              User nobody
            Host "quoted name"
            """)
        XCTAssertEqual(config.hosts.map(\.alias), ["jump", "quoted name"])
        XCTAssertEqual(config.hosts[0].user, "me")
        XCTAssertNil(config.hosts[1].user)
    }

    func testBooMetaAboveAndInsideBlock() {
        let config = parse(
            """
            # boo: group=prod tags=db,eu
            Host a
            Host b
              # boo: group=staging
              User x
            # plain comment
            Host c
            """)
        XCTAssertEqual(config.hosts[0].group, "prod")
        XCTAssertEqual(config.hosts[0].tags, ["db", "eu"])
        XCTAssertEqual(config.hosts[1].group, "staging")
        XCTAssertNil(config.hosts[2].group)
    }

    func testIncludeRelativeGlobAndCycle() {
        write("conf.d/b.conf", "Host b\nInclude config\n")
        write("conf.d/a.conf", "Host a\n  User ua\n")
        let root = write("config", "Include conf.d/*.conf\nHost root\nHost a\n")
        let config = SSHConfigParser.parse(path: root, sshDir: dir)
        XCTAssertEqual(config.hosts.map(\.alias), ["a", "b", "root"])
        XCTAssertEqual(config.hosts[0].user, "ua")
        XCTAssertTrue(config.hosts[0].file.hasSuffix("conf.d/a.conf"))
        XCTAssertEqual(config.files.count, 3)
        XCTAssertEqual(config.files.first, (root as NSString).standardizingPath)
    }

    func testMissingFileIsEmpty() {
        let config = SSHConfigParser.parse(path: (dir as NSString).appendingPathComponent("nope"), sshDir: dir)
        XCTAssertEqual(config.hosts, [])
        XCTAssertEqual(config.files.count, 1)
    }

    func testCommandLineDestination() {
        XCTAssertEqual(SSHCommandLine.destination(of: "ssh web"), "web")
        XCTAssertEqual(SSHCommandLine.destination(of: "ssh -p 22 -A me@web uptime"), "me@web")
        XCTAssertEqual(SSHCommandLine.destination(of: "ssh -p22 -i ~/.ssh/k web"), "web")
        XCTAssertEqual(SSHCommandLine.destination(of: "/usr/bin/ssh -tt -- web"), "web")
        XCTAssertEqual(SSHCommandLine.destination(of: "ssh -o 'ServerAliveInterval 5' web"), "web")
        XCTAssertNil(SSHCommandLine.destination(of: "sshfs web:/ /mnt"))
        XCTAssertNil(SSHCommandLine.destination(of: "ssh -v"))
        XCTAssertEqual(SSHCommandLine.host(of: "me@web"), "web")
        XCTAssertEqual(SSHCommandLine.host(of: "ssh://me@web:2222"), "web")
    }

    func testGroupingAndFilter() {
        let hosts = [
            SSHHost(alias: "a", file: "", line: 1),
            SSHHost(alias: "b", group: "prod", file: "", line: 2),
            SSHHost(alias: "c", group: "dev", tags: ["gpu"], file: "", line: 3),
            SSHHost(alias: "d", file: "", line: 4)
        ]
        let recent = ["d": Date()]
        let groups = HostsPanelView.grouped(hosts, filter: "", recent: recent)
        XCTAssertEqual(groups.map(\.name), ["dev", "prod", nil])
        XCTAssertEqual(groups.last?.hosts.map(\.alias), ["d", "a"])
        XCTAssertEqual(HostsPanelView.grouped(hosts, filter: "GPU", recent: [:]).flatMap(\.hosts).map(\.alias), ["c"])
    }
}
