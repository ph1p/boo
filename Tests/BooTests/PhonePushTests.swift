import XCTest

@testable import Boo

final class PhonePushTests: XCTestCase {
    private func query(_ req: URLRequest) -> [String: String] {
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testRequestCarriesOnlyMetadata() throws {
        let req = try XCTUnwrap(
            PhonePush.request(
                topicURL: " https://ntfy.sh/secret-topic ", event: .agentNeedsInput, workspaceName: "Büro",
                agentName: "Claude", clickURL: "http://10.0.0.2:8899/"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.host, "ntfy.sh")
        XCTAssertEqual(req.url?.path, "/secret-topic")
        XCTAssertEqual(req.timeoutInterval, PhonePush.timeout)
        let q = query(req)
        XCTAssertEqual(Set(q.keys), ["title", "tags", "click"])
        XCTAssertEqual(q["title"], "Büro")
        XCTAssertEqual(q["click"], "http://10.0.0.2:8899/")
        XCTAssertEqual(String(data: req.httpBody ?? Data(), encoding: .utf8), "Claude needs your input")
    }

    func testMessagesNeverIncludeCommandText() {
        for event in PhonePush.Event.allCases {
            let msg = PhonePush.message(for: event, workspaceName: "ws", agentName: nil)
            XCTAssertEqual(msg.title, "ws")
            XCTAssertFalse(msg.body.isEmpty)
        }
        XCTAssertEqual(PhonePush.message(for: .longCommand, workspaceName: "", agentName: nil).title, "Boo")
    }

    func testRequestKeepsExistingQueryAndOmitsMissingClick() throws {
        let req = try XCTUnwrap(
            PhonePush.request(
                topicURL: "http://ntfy.lan/t?auth=abc", event: .sshDropped, workspaceName: "w", agentName: nil,
                clickURL: nil))
        let q = query(req)
        XCTAssertEqual(q["auth"], "abc")
        XCTAssertNil(q["click"])
        XCTAssertEqual(String(data: req.httpBody ?? Data(), encoding: .utf8), "SSH connection dropped")
    }

    func testRejectsNonHTTPURLs() {
        for bad in ["", "ntfy.sh/topic", "file:///etc/passwd", "ftp://x/y", "https://"] {
            XCTAssertNil(
                PhonePush.request(topicURL: bad, event: .longCommand, workspaceName: "w", agentName: nil, clickURL: nil),
                bad)
        }
    }

    func testClassify() {
        XCTAssertEqual(PhonePush.classify(command: "make", duration: 61, exitCode: 0, threshold: 60), .longCommand)
        XCTAssertEqual(PhonePush.classify(command: "make", duration: 61, exitCode: 2, threshold: 60), .longCommand)
        XCTAssertNil(PhonePush.classify(command: "make", duration: 59, exitCode: 0, threshold: 60))
        XCTAssertEqual(PhonePush.classify(command: "ssh prod", duration: 600, exitCode: 255, threshold: 60), .sshDropped)
        XCTAssertNil(PhonePush.classify(command: "ssh prod", duration: 600, exitCode: 0, threshold: 60))
        XCTAssertNil(PhonePush.classify(command: "ssh prod", duration: 1, exitCode: 255, threshold: 60))
        XCTAssertEqual(
            PhonePush.classify(command: "TERM=xterm /usr/bin/ssh -p 22 h", duration: 30, exitCode: 255, threshold: 60),
            .sshDropped)
        XCTAssertFalse(PhonePush.isSSH("sshfs h:/ /mnt"))
        XCTAssertFalse(PhonePush.isSSH(""))
    }

    func testThrottlePerEventType() {
        var throttle = PhonePush.Throttle()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(throttle.allow(.longCommand, now: t0))
        XCTAssertFalse(throttle.allow(.longCommand, now: t0.addingTimeInterval(9)))
        XCTAssertTrue(throttle.allow(.sshDropped, now: t0.addingTimeInterval(9)))
        XCTAssertTrue(throttle.allow(.longCommand, now: t0.addingTimeInterval(10)))
    }

    func testDisabledByDefault() {
        let defaults = UserDefaults.standard
        let saved = (
            defaults.object(forKey: "phonePushEnabled"), defaults.object(forKey: "phonePushLongCommandSeconds")
        )
        defer {
            defaults.set(saved.0, forKey: "phonePushEnabled")
            defaults.set(saved.1, forKey: "phonePushLongCommandSeconds")
        }
        defaults.removeObject(forKey: "phonePushEnabled")
        defaults.removeObject(forKey: "phonePushLongCommandSeconds")
        XCTAssertFalse(AppSettings.shared.phonePushEnabled)
        XCTAssertEqual(AppSettings.shared.phonePushLongCommandSeconds, 60)
    }

    func testRemoteServerServesInstallAssets() {
        for path in ["/manifest.webmanifest", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"] {
            let asset = RemoteControlServer.staticAssets[path]
            XCTAssertNotNil(asset, path)
            XCTAssertNotNil(
                asset.flatMap {
                    BooResourceBundle.bundle.url(forResource: $0.name, withExtension: $0.ext, subdirectory: "RemoteControl")
                }, path)
        }
    }
}
