import XCTest

@testable import Exterm

final class DockerServiceTests: XCTestCase {

    func testDockerDetection() {
        let docker = DockerService.shared
        // isAvailable depends on whether Docker is installed on the test machine
        // Just verify it doesn't crash
        docker.detectDocker()
        // dockerPath should be set if available
        if docker.isAvailable {
            XCTAssertNotNil(docker.dockerPath)
        } else {
            XCTAssertNil(docker.dockerPath)
        }
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

    func testStartStopPolling() {
        let docker = DockerService.shared
        // Should not crash even if Docker is not available
        docker.startPolling(interval: 60)
        docker.stopPolling()
    }

    func testContainerStateValues() {
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "restarting"), .restarting)
        XCTAssertEqual(DockerService.Container.ContainerState(rawValue: "dead"), .dead)
    }

    @MainActor
    func testDockerPluginSectionTitle() {
        let plugin = DockerPluginNew()
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "zsh",
            paneCount: 1,
            tabCount: 1
        )
        // With no containers, section title should be nil
        let title = plugin.sectionTitle(context: ctx)
        // Containers come from DockerService.shared which may or may not have real data
        if DockerService.shared.containers.isEmpty {
            XCTAssertNil(title)
        } else {
            XCTAssertNotNil(title)
            XCTAssertTrue(title!.contains("Docker"))
        }
    }

    @MainActor
    func testDockerPluginStatusBarContent() {
        let plugin = DockerPluginNew()
        let ctx = TerminalContext(
            terminalID: UUID(),
            cwd: "/tmp",
            remoteSession: nil,
            gitContext: nil,
            processName: "zsh",
            paneCount: 1,
            tabCount: 1
        )
        if DockerService.shared.containers.isEmpty {
            XCTAssertNil(plugin.makeStatusBarContent(context: ctx))
        } else {
            let content = plugin.makeStatusBarContent(context: ctx)
            XCTAssertNotNil(content)
            XCTAssertTrue(content!.text.contains("running"))
        }
    }
}
