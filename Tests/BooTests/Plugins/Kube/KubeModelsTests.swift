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
            KubeWorkload.parse(
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
        var pods = KubeCollection<KubeWorkload>()
        pods.apply(.added, KubeWorkload(name: "b", replicas: 1, ready: 0, updated: 0))
        pods.apply(.added, KubeWorkload(name: "a", replicas: 1, ready: 0, updated: 0))
        pods.apply(.modified, KubeWorkload(name: "b", replicas: 2, ready: 2, updated: 2))
        XCTAssertEqual(pods.items.map(\.name), ["a", "b"])
        XCTAssertEqual(pods.items[1].ready, 2)
        pods.apply(.deleted, KubeWorkload(name: "a", replicas: 1, ready: 0, updated: 0))
        XCTAssertEqual(pods.items.map(\.name), ["b"])
    }

    func testCommands() {
        XCTAssertEqual(
            KubeCommand.logs("deployment/web", container: nil, context: "prod", namespace: "shop"),
            "kubectl --context prod -n shop logs -f --tail 200 deployment/web --all-containers --prefix")
        XCTAssertEqual(
            KubeCommand.portForward("svc/web", port: 80, localPort: 8080, context: "prod", namespace: "shop"),
            "kubectl --context prod -n shop port-forward svc/web 8080:80")
        XCTAssertEqual(
            KubeCommand.portForward("pod/x", port: 3000, localPort: 3000, context: nil, namespace: nil),
            "kubectl port-forward pod/x 3000:3000")
        XCTAssertTrue(
            KubeCommand.exec("api-1", container: "api", context: "a b", namespace: "n")
                .hasPrefix("kubectl --context 'a b' -n n exec -it api-1 -c api -- sh -c"))
    }

    func testWorkloadJobCronJobIngressParse() throws {
        let daemonset = try XCTUnwrap(
            KubeWorkload.parse(
                object(
                    #"{"metadata": {"name": "ds"}, "status": {"desiredNumberScheduled": 3, "numberReady": 2}}"#)))
        XCTAssertEqual(daemonset.replicas, 3)
        XCTAssertEqual(daemonset.ready, 2)
        XCTAssertFalse(daemonset.healthy)

        let failed = try XCTUnwrap(
            KubeJob.parse(
                object(
                    """
                    {"metadata": {"name": "j"}, "spec": {"completions": 1},
                     "status": {"conditions": [{"type": "Failed", "status": "True"}]}}
                    """)))
        XCTAssertEqual(failed.health, .failed)
        let done = try XCTUnwrap(
            KubeJob.parse(object(#"{"metadata": {"name": "j"}, "status": {"succeeded": 1}}"#)))
        XCTAssertEqual(done.health, .complete)
        let running = try XCTUnwrap(
            KubeJob.parse(object(#"{"metadata": {"name": "j"}, "status": {"active": 1}}"#)))
        XCTAssertEqual(running.health, .running)

        let cron = try XCTUnwrap(
            KubeCronJob.parse(
                object(
                    """
                    {"metadata": {"name": "c"}, "spec": {"schedule": "*/5 * * * *", "suspend": true},
                     "status": {"active": [{"name": "x"}], "lastScheduleTime": "2026-10-20T10:00:00Z"}}
                    """)))
        XCTAssertEqual(cron.schedule, "*/5 * * * *")
        XCTAssertTrue(cron.suspended)
        XCTAssertEqual(cron.active, 1)
        XCTAssertNotNil(cron.lastSchedule)

        let ingress = try XCTUnwrap(
            KubeIngress.parse(
                object(
                    """
                    {"metadata": {"name": "i"}, "spec": {"tls": [{"hosts": ["a.example"]}],
                     "rules": [{"host": "a.example"}, {"host": "b.example"}, {"host": "a.example"}]}}
                    """)))
        XCTAssertEqual(ingress.hosts, ["a.example", "b.example"])
        XCTAssertEqual(ingress.url(for: "a.example")?.absoluteString, "https://a.example")
    }

    func testCollectionStaleRelist() {
        var items = KubeCollection<KubeWorkload>()
        items.apply(.added, KubeWorkload(name: "a", replicas: 1, ready: 1, updated: 1))
        items.apply(.added, KubeWorkload(name: "b", replicas: 1, ready: 1, updated: 1))
        items.markStale()
        // Rows stay visible while the new watch re-lists.
        XCTAssertEqual(items.items.map(\.name), ["a", "b"])
        items.apply(.added, KubeWorkload(name: "b", replicas: 1, ready: 1, updated: 1))
        items.dropStale()
        XCTAssertEqual(items.items.map(\.name), ["b"])
        XCTAssertTrue(items.stale.isEmpty)
    }

    func testFreeLocalPortSkipsTakenPorts() {
        XCTAssertEqual(KubeCommand.freeLocalPort(for: 80, isFree: { $0 != 8080 && $0 != 8081 }), 8082)
        XCTAssertEqual(KubeCommand.freeLocalPort(for: 3000, isFree: { _ in true }), 3000)
        XCTAssertEqual(
            KubeCommand.portForward("svc/web", port: 80, localPort: 8082, context: nil, namespace: nil),
            "kubectl port-forward svc/web 8082:80")
        XCTAssertEqual(
            KubeCommand.logs("pod/x", container: nil, previous: true, context: nil, namespace: nil),
            "kubectl logs --previous --tail 500 pod/x")
    }

    func testManualJobNameFitsDNSLabel() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(KubeStore.manualJobName(for: "backup", date: date), "backup-manual-1800000000")
        let long = KubeStore.manualJobName(for: String(repeating: "x", count: 70), date: date)
        XCTAssertEqual(long.count, 63)
        XCTAssertTrue(long.hasSuffix("-manual-1800000000"))
    }

    func testWildcardIngressHostHasNoURL() {
        let ingress = KubeIngress(name: "web", hosts: ["*.example.com", "app.example.com"], tls: true)
        XCTAssertNil(ingress.url(for: "*.example.com"))
        XCTAssertEqual(ingress.url(for: "app.example.com")?.absoluteString, "https://app.example.com")
    }
}
