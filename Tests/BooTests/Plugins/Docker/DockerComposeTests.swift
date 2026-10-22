import XCTest

@testable import Boo

final class DockerComposeTests: XCTestCase {
    private let fixture = """
        [
          {"Id": "aaaaaaaaaaaaaaaa", "Names": ["/shop-web-1"], "Image": "node", "Status": "Up 2 minutes",
           "State": "running", "Created": 1700000000,
           "Labels": {"com.docker.compose.project": "shop", "com.docker.compose.service": "web",
                      "com.docker.compose.project.working_dir": "/src/shop",
                      "com.docker.compose.project.config_files": "/src/shop/compose.yaml, /src/shop/compose.dev.yaml"}},
          {"Id": "bbbbbbbbbbbbbbbb", "Names": ["/shop-db-1"], "Image": "postgres", "Status": "Exited (0)",
           "State": "exited", "Labels": {"com.docker.compose.project": "shop", "com.docker.compose.service": "db"}},
          {"Id": "cccccccccccccccc", "Names": ["/api-app-1"], "Image": "go", "Status": "Up", "State": "running",
           "Labels": {"com.docker.compose.project": "api", "com.docker.compose.project.working_dir": "/src/api"}},
          {"Id": "dddddddddddddddd", "Names": ["/lonely"], "Image": "redis", "Status": "Up", "State": "running",
           "Labels": {}}
        ]
        """

    private var containers: [DockerService.Container] {
        DockerService.parseContainersJSON(fixture.data(using: .utf8))
    }

    func testParsesComposeLabels() {
        let web = containers[0]
        XCTAssertEqual(web.composeProject, "shop")
        XCTAssertEqual(web.composeService, "web")
        XCTAssertEqual(web.composeWorkingDir, "/src/shop")
        XCTAssertEqual(web.composeConfigFiles, ["/src/shop/compose.yaml", "/src/shop/compose.dev.yaml"])
        XCTAssertNil(containers[3].composeProject)
    }

    func testGroupsByProjectSortedWithServicesOrdered() {
        let groups = ComposeGrouping.group(containers, pinnedFolder: nil)
        XCTAssertEqual(groups.projects.map(\.displayName), ["api", "shop"])
        XCTAssertEqual(groups.projects[1].containers.map(\.composeService), ["db", "web"])
        XCTAssertEqual(groups.projects[1].runningCount, 1)
        XCTAssertEqual(groups.projects[1].configFiles.count, 2)
        XCTAssertEqual(groups.loose.map(\.name), ["lonely"])
    }

    func testPinnedFolderMovesProjectFirstOrAddsPlaceholder() {
        let pinned = ComposeGrouping.group(containers, pinnedFolder: "/src/shop")
        XCTAssertEqual(pinned.projects.map(\.displayName), ["shop", "api"])
        XCTAssertTrue(pinned.projects[0].isPinned)

        let placeholder = ComposeGrouping.group(containers, pinnedFolder: "/src/blog")
        XCTAssertEqual(placeholder.projects.first?.displayName, "blog")
        XCTAssertNil(placeholder.projects.first?.name)
        XCTAssertEqual(placeholder.projects.first?.containers, [])
    }

    func testArguments() {
        let shop = ComposeGrouping.group(containers, pinnedFolder: nil).projects[1]
        let exists: (String) -> Bool = { $0 == "/src/shop/compose.yaml" }
        XCTAssertEqual(
            shop.arguments(.up, fileExists: exists),
            ["compose", "-p", "shop", "-f", "/src/shop/compose.yaml", "--project-directory", "/src/shop", "up", "-d"])
        XCTAssertEqual(
            shop.arguments(.down, fileExists: exists),
            ["compose", "-p", "shop", "-f", "/src/shop/compose.yaml", "down"])
        let blog = ComposeProject(name: nil, workingDir: "/src/blog", isPinned: true)
        XCTAssertEqual(blog.arguments(.up), ["compose", "--project-directory", "/src/blog", "up", "-d"])
        XCTAssertEqual(blog.shellCommand("logs -f"), "docker compose --project-directory /src/blog logs -f")
    }

    func testHasComposeFile() {
        XCTAssertTrue(ComposeGrouping.hasComposeFile(in: "/x", fileExists: { $0 == "/x/docker-compose.yml" }))
        XCTAssertFalse(ComposeGrouping.hasComposeFile(in: "/x", fileExists: { _ in false }))
    }
}
