import XCTest

@testable import Boo

final class KubeModelsTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testSplitterHandlesPrettyPrintedChunks() {
        let stream = """
            {
                "type": "ADDED",
                "object": {"metadata": {"name": "a}b\\"{"}}
            }
            {"type": "DELETED", "object": {"metadata": {"name": "c"}}}
            """
        var splitter = JSONObjectStreamSplitter()
        var objects: [Data] = []
        // Byte-sized chunks cut through strings, escapes and braces.
        for byte in Data(stream.utf8) { objects += splitter.feed(Data([byte])) }
        XCTAssertEqual(objects.count, 2)
        let events = objects.compactMap(KubeWatchEvent.parse)
        XCTAssertEqual(events.map(\.kind), [.added, .deleted])
        XCTAssertEqual((events[0].object["metadata"] as? [String: Any])?["name"] as? String, "a}b\"{")
    }

    func testSplitterKeepsPartialObject() {
        var splitter = JSONObjectStreamSplitter()
        XCTAssertTrue(splitter.feed(Data(#"{"type":"ADDED","obj"#.utf8)).isEmpty)
        let rest = splitter.feed(Data(#"ect":{}} {"a":1}"#.utf8))
        XCTAssertEqual(rest.count, 2)
        XCTAssertEqual(String(data: rest[1], encoding: .utf8), #"{"a":1}"#)
    }

    func testPodParse() throws {
        let pod = try XCTUnwrap(
            KubePod.parse(
                object(
                    """
                    {"metadata": {"name": "api-1", "creationTimestamp": "2026-10-20T10:00:00Z"},
                     "spec": {"containers": [{"name": "api", "ports": [{"containerPort": 8080}]}, {"name": "proxy"}]},
                     "status": {"phase": "Running", "containerStatuses": [
                        {"name": "api", "ready": true, "restartCount": 2, "state": {"running": {}}},
                        {"name": "proxy", "ready": false, "restartCount": 5,
                         "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}}
                    """)))
        XCTAssertEqual(pod.status, "CrashLoopBackOff")
        XCTAssertEqual(pod.health, .failing)
        XCTAssertEqual(pod.ready, 1)
        XCTAssertEqual(pod.total, 2)
        XCTAssertEqual(pod.restarts, 7)
        XCTAssertEqual(pod.containers, ["api", "proxy"])
        XCTAssertEqual(pod.ports, [8080])
        XCTAssertNotNil(pod.createdAt)
    }

    func testPodTerminatingAndInit() throws {
        let terminating = try XCTUnwrap(
            KubePod.parse(
                object(
                    #"{"metadata": {"name": "p", "deletionTimestamp": "2026-10-20T10:00:00Z"}, "status": {"phase": "Running"}}"#
                )))
        XCTAssertEqual(terminating.status, "Terminating")
        XCTAssertEqual(terminating.health, .pending)
        let initPod = try XCTUnwrap(
            KubePod.parse(
                object(
                    """
                    {"metadata": {"name": "p"}, "status": {"phase": "Pending",
                     "initContainerStatuses": [{"state": {"waiting": {"reason": "ImagePullBackOff"}}}]}}
                    """)))
        XCTAssertEqual(initPod.status, "Init:ImagePullBackOff")
        let ok = try XCTUnwrap(
            KubePod.parse(object(#"{"metadata": {"name": "p"}, "status": {"phase": "Succeeded"}}"#)))
        XCTAssertEqual(ok.status, "Succeeded")
        XCTAssertEqual(ok.health, .done)
    }

    func testDeploymentAndServiceParse() throws {
        let deploy = try XCTUnwrap(
            KubeDeployment.parse(
                object(#"{"metadata": {"name": "web"}, "spec": {"replicas": 3}, "status": {"readyReplicas": 2}}"#)))
        XCTAssertEqual(deploy.replicas, 3)
        XCTAssertEqual(deploy.ready, 2)
        let svc = try XCTUnwrap(
            KubeSvc.parse(
                object(
                    """
                    {"metadata": {"name": "web"}, "spec": {"type": "NodePort", "clusterIP": "10.0.0.1",
                     "ports": [{"port": 80, "protocol": "TCP", "nodePort": 30080}, {"port": 53, "protocol": "UDP"}]}}
                    """)))
        XCTAssertEqual(svc.type, "NodePort")
        XCTAssertEqual(svc.clusterIP, "10.0.0.1")
        XCTAssertEqual(svc.portsLabel, "80:30080,53/UDP")
        let headless = try XCTUnwrap(
            KubeSvc.parse(object(#"{"metadata": {"name": "h"}, "spec": {"clusterIP": "None"}}"#)))
        XCTAssertNil(headless.clusterIP)
    }

    func testConfigParse() throws {
        let info = try XCTUnwrap(
            KubeConfigInfo.parse(
                Data(
                    """
                    {"current-context": "prod", "contexts": [
                      {"name": "prod", "context": {"cluster": "c", "namespace": "shop"}},
                      {"name": "dev", "context": {"cluster": "d"}}]}
                    """.utf8)))
        XCTAssertEqual(info.current, "prod")
        XCTAssertEqual(info.namespace, "shop")
        XCTAssertEqual(info.contextNames, ["dev", "prod"])
        var dev = info
        dev.current = "dev"
        XCTAssertEqual(dev.namespace, "default")
        XCTAssertNil(KubeConfigInfo.parse(Data(#"{"current-context": ""}"#.utf8))?.current)
    }

    func testCollectionAppliesEvents() {
        var pods = KubeCollection<KubeDeployment>()
        pods.apply(.added, KubeDeployment(name: "b", replicas: 1, ready: 0, updated: 0))
        pods.apply(.added, KubeDeployment(name: "a", replicas: 1, ready: 0, updated: 0))
        pods.apply(.modified, KubeDeployment(name: "b", replicas: 2, ready: 2, updated: 2))
        XCTAssertEqual(pods.items.map(\.name), ["a", "b"])
        XCTAssertEqual(pods.items[1].ready, 2)
        pods.apply(.deleted, KubeDeployment(name: "a", replicas: 1, ready: 0, updated: 0))
        XCTAssertEqual(pods.items.map(\.name), ["b"])
    }

    func testCommands() {
        XCTAssertEqual(
            KubeCommand.logs("deployment/web", container: nil, context: "prod", namespace: "shop"),
            "kubectl --context prod -n shop logs -f --tail 200 deployment/web --all-containers")
        XCTAssertEqual(
            KubeCommand.portForward("svc/web", port: 80, context: "prod", namespace: "shop"),
            "kubectl --context prod -n shop port-forward svc/web 8080:80")
        XCTAssertEqual(
            KubeCommand.portForward("pod/x", port: 3000, context: nil, namespace: nil),
            "kubectl port-forward pod/x 3000:3000")
        XCTAssertTrue(
            KubeCommand.exec("api-1", container: "api", context: "a b", namespace: "n")
                .hasPrefix("kubectl --context 'a b' -n n exec -it api-1 -c api -- sh -c"))
    }
}
