import XCTest

@testable import Boo

final class DockerServiceTests: XCTestCase {

    func testDockerDetection() {
        let docker = DockerService.shared
        // isAvailable depends on whether Docker socket exists on the test machine
        docker.detectDocker()
        if docker.isAvailable {
            XCTAssertNotNil(docker.socketPath)
            XCTAssertNil(docker.connectionError)
        } else {
            XCTAssertNil(docker.socketPath)
            XCTAssertNotNil(docker.connectionError)
        }
    }

    func testExplicitSocketPathNotFound() {
        let docker = DockerService.shared
        docker.detectDocker(explicitPath: "/nonexistent/docker.sock")
        XCTAssertFalse(docker.isAvailable)
        XCTAssertNil(docker.socketPath)
        XCTAssertNotNil(docker.connectionError)
        XCTAssertTrue(docker.connectionError!.contains("/nonexistent"))
        // Restore auto-detect
        docker.detectDocker()
    }

    func testExplicitSocketPathEmpty() {
        let docker = DockerService.shared
        // Empty string should fall back to auto-detect
        docker.detectDocker(explicitPath: "")
        if docker.isAvailable {
            XCTAssertNil(docker.connectionError)
        }
        // Restore
        docker.detectDocker()
    }

    func testContainerStateEnum() {
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "running"), .running)
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "exited"), .exited)
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "paused"), .paused)
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "created"), .created)
        XCTAssertNil(DockerService.Container.ContainerState(rawValue: "nonsense"))
    }

    func testExecCommand() {
        let container = DockerService.Container(
            id: "abc123",
            name: "myapp",
            image: "nginx:latest",
            status: "Up 2 hours",
            state: .running,
            ports: "80/tcp"
        )
        let cmd = DockerService.shared.execCommand(for: container)
        XCTAssertEqual(cmd, "docker exec -it myapp sh\r")
    }

    func testContainerEquatable() {
        let a = DockerService.Container(id: "abc", name: "x", image: "y", status: "Up", state: .running, ports: "")
        let b = DockerService.Container(id: "abc", name: "x", image: "y", status: "Up", state: .running, ports: "")
        let c = DockerService.Container(id: "def", name: "x", image: "y", status: "Up", state: .running, ports: "")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testStartStopWatching() {
        let docker = DockerService.shared
        // Should not crash even if Docker is not available
        docker.startWatching()
        docker.stopWatching()
    }

    func testContainerStateValues() {
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "restarting"), .restarting)
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "dead"), .dead)
    }

    @MainActor
    func testDockerPluginSectionTitle() {
        let plugin = DockerPluginNew()
        let ctx = PluginContext(
            terminal: TerminalContext(
                terminalID: UUID(),
                cwd: "/tmp",
                remoteSession: nil,
                gitContext: nil,
                processName: "zsh",
                paneCount: 1,
                tabCount: 1
            ),
            theme: ThemeSnapshot(from: .defaultDark),
            density: .comfortable,
            settings: PluginSettingsReader(pluginID: plugin.manifest.id),
            fontScale: SidebarFontScale(base: 12)
        )
        let title = plugin.sectionTitle(context: ctx)
        if DockerService.shared.connectionError != nil {
            XCTAssertEqual(title, "Docker (disconnected)")
        } else if !DockerService.shared.containers.isEmpty {
            XCTAssertNotNil(title)
            XCTAssertTrue(title!.contains("Docker"))
        } else {
            XCTAssertNil(title)
        }
    }

    @MainActor
    func testDockerPluginStatusBarContent() {
        let plugin = DockerPluginNew()
        let ctx = PluginContext(
            terminal: TerminalContext(
                terminalID: UUID(),
                cwd: "/tmp",
                remoteSession: nil,
                gitContext: nil,
                processName: "zsh",
                paneCount: 1,
                tabCount: 1
            ),
            theme: ThemeSnapshot(from: .defaultDark),
            density: .comfortable,
            settings: PluginSettingsReader(pluginID: plugin.manifest.id),
            fontScale: SidebarFontScale(base: 12)
        )
        let content = plugin.makeStatusBarContent(context: ctx)
        if DockerService.shared.connectionError != nil {
            XCTAssertNotNil(content)
            XCTAssertEqual(content!.text, "disconnected")
        } else if !DockerService.shared.containers.isEmpty {
            XCTAssertNotNil(content)
            XCTAssertTrue(content!.text.contains("running"))
        } else {
            XCTAssertNil(content)
        }
    }

    @MainActor
    func testDockerPluginHasSocketPathSetting() {
        let plugin = DockerPluginNew()
        let settings = plugin.manifest.settings ?? []
        let socketSetting = settings.first { $0.key == "socketPath" }
        XCTAssertNotNil(socketSetting)
        XCTAssertEqual(socketSetting?.type, .string)
    }
}
