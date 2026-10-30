import XCTest

@testable import Boo

final class PhonePushTests: XCTestCase {

    func testOffByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "phonePushURL")
        defer { defaults.set(saved, forKey: "phonePushURL") }
        defaults.removeObject(forKey: "phonePushURL")
        XCTAssertEqual(AppSettings.shared.phonePushURL, "")
        XCTAssertNil(PhonePush.endpoint(AppSettings.shared.phonePushURL))
    }

    func testEndpointAcceptsOnlyHTTPURLsWithHost() {
        XCTAssertNotNil(PhonePush.endpoint("https://ntfy.sh/boo-abc123"))
        XCTAssertNotNil(PhonePush.endpoint("  http://10.0.0.2:8080/topic "))
        XCTAssertNil(PhonePush.endpoint(""))
        XCTAssertNil(PhonePush.endpoint("ntfy.sh/topic"))
        XCTAssertNil(PhonePush.endpoint("file:///etc/passwd"))
        XCTAssertNil(PhonePush.endpoint("https://"))
    }

    func testThrottlePerEventKind() {
        let now = Date()
        let sent: [PhonePush.Event: Date] = [.agentWaiting: now.addingTimeInterval(-3)]
        XCTAssertFalse(PhonePush.allows(.agentWaiting, at: now, lastSent: sent))
        XCTAssertTrue(PhonePush.allows(.commandFinished, at: now, lastSent: sent))
        XCTAssertTrue(
            PhonePush.allows(.agentWaiting, at: now.addingTimeInterval(PhonePush.throttle), lastSent: sent))
    }

    /// The request carries only what the builder was given: workspace, subject
    /// and fixed wording. The Click link never carries the remote-control token.
    func testRequestCarriesOnlyEventMetadata() throws {
        let message = PhonePush.message(for: .agentWaiting, workspaceName: "boo", subject: "Claude Code")
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/topic"))
        let request = PhonePush.request(url: url, message: message, click: "http://192.168.1.4:7681/")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Title"), "boo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Tags"), "robot")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Click"), "http://192.168.1.4:7681/")
        XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "Claude Code is waiting for you")
    }

    func testLinkWithoutTokenHasNoFragment() {
        let server = RemoteControlServer.shared
        XCTAssertFalse(server.linkWithoutToken.contains("#"))
        XCTAssertTrue(server.accessURL.hasPrefix(server.linkWithoutToken + "#"))
    }

    func testNonASCIITitleIsEncodedForTheHeader() {
        XCTAssertEqual(PhonePush.headerSafe("boo"), "boo")
        let encoded = PhonePush.headerSafe("Café")
        XCTAssertTrue(encoded.hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(encoded.allSatisfy(\.isASCII))
    }

    func testDroppedRemoteSessionNeedsSSHAndExit255() {
        XCTAssertTrue(PhonePush.isDroppedRemoteSession(command: "ssh prod", exitCode: 255))
        XCTAssertTrue(PhonePush.isDroppedRemoteSession(command: "/usr/bin/ssh -p 22 prod", exitCode: 255))
        XCTAssertTrue(PhonePush.isDroppedRemoteSession(command: "mosh dev", exitCode: 255))
        XCTAssertFalse(PhonePush.isDroppedRemoteSession(command: "ssh prod", exitCode: 0))
        XCTAssertFalse(PhonePush.isDroppedRemoteSession(command: "ssh prod", exitCode: nil))
        XCTAssertFalse(PhonePush.isDroppedRemoteSession(command: "make ssh", exitCode: 255))
    }

    func testRemoteHostSkipsOptionsAndUser() {
        XCTAssertEqual(PhonePush.remoteHost(in: "ssh -p 2222 -A deploy@web1"), "web1")
        XCTAssertEqual(PhonePush.remoteHost(in: "ssh -i ~/.ssh/key host"), "host")
        XCTAssertNil(PhonePush.remoteHost(in: "ssh -v"))
    }

    func testCompactDuration() {
        XCTAssertEqual(DurationFormat.compact(42), "42s")
        XCTAssertEqual(DurationFormat.compact(125), "2m 5s")
        XCTAssertEqual(DurationFormat.compact(3720), "1h 2m")
    }
}
