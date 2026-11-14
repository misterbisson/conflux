import Foundation
import Testing
@testable import ConfluxCore

/// A device serving two hosts to its peers, a model file and Apple's model,
/// behind a host service on loopback. `serving` changes which it lists, as
/// the device's owner turning Apple's model on or off would.
final class TwoHostPeer: @unchecked Sendable {
    let file = FakeHost(id: ConfluxNode.localHostID, model: "model-a")
    let apple = FakeHost(id: ConfluxNode.appleHostID, model: AppleModelHost.modelID, capabilities: [.text, .vision],
                         slots: 2)
    let scheduler: Scheduler
    let server: HTTPServer
    let base: URL
    private let current: Current

    final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var service: HostService
        init(_ service: HostService) { self.service = service }
        var now: HostService {
            get { lock.withLock { service } }
            set { lock.withLock { service = newValue } }
        }
    }

    init() async throws {
        let scheduler = await Scheduler.with([file, apple])
        self.scheduler = scheduler
        let current = Current(HostService(scheduler: scheduler,
                                          hostIDs: [ConfluxNode.localHostID, ConfluxNode.appleHostID]))
        self.current = current
        server = HTTPServer(onlyFromThisProcess: true) { request in await current.now.handle(request) }
        let port = try await server.start(port: 0)
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    func serve(_ hostIDs: [String]) {
        current.now = HostService(scheduler: scheduler, hostIDs: hostIDs)
    }

    var link: FixedLink { FixedLink(base: base) }
}

let peerEndpoint = String(repeating: "ab", count: 32)

@Suite struct PeerHostsTests {
    @Test func idsNameTheHostOnThePeer() {
        #expect(RemoteHost.id(peerEndpoint) == "peer-ababababab")
        #expect(RemoteHost.id(peerEndpoint, "apple") == "peer-ababababab-apple")
        #expect(RemoteHost.hostOnPeer(in: "peer-ababababab-apple") == "apple")
        #expect(RemoteHost.hostOnPeer(in: "peer-ababababab") == nil)
        #expect(RemoteHost.hostOnPeer(in: ConfluxNode.appleHostID) == nil)
        #expect(PeerStatus(endpointID: peerEndpoint, hostID: "peer-ababababab", path: .none).hostIDs
            == ["peer-ababababab"])
        #expect(PeerStatus(endpointID: peerEndpoint, hostID: "", path: .none).hostIDs.isEmpty)
    }

    /// The status names the host it describes and lists the device's others;
    /// `Conflux-Host` picks one.
    @Test func theHostServiceAnswersForEachHost() async throws {
        let peer = try await TwoHostPeer()
        defer { peer.server.stop() }
        let first = RemoteHost(endpointID: peerEndpoint, link: peer.link)
        await first.refresh()
        #expect(await first.model?.id == "model-a")
        #expect(first.otherHosts == [ConfluxNode.appleHostID])

        let apple = RemoteHost(endpointID: peerEndpoint, link: peer.link, hostOnPeer: ConfluxNode.appleHostID)
        await apple.refresh()
        #expect(apple.id == "peer-ababababab-apple")
        #expect(await apple.model?.id == AppleModelHost.modelID)
        #expect(await apple.availability == .available)
        #expect(apple.slots == 2)
        // Only the first hears of the others.
        #expect(apple.otherHosts.isEmpty)

        let reply = try await apple.complete(Data("{}".utf8), timeout: 10)
        #expect(reply.status == 200)
        #expect(reply.model?.id == AppleModelHost.modelID)
        #expect(peer.apple.calls == 1)
        #expect(peer.file.calls == 0)

        // One the device doesn't serve is offline, and takes no work.
        let gone = RemoteHost(endpointID: peerEndpoint, link: peer.link, hostOnPeer: "mlx")
        await gone.refresh()
        #expect(await gone.availability == .offline)
        #expect(await gone.model == nil)
        #expect(gone.slots == 0)
        await #expect(throws: HostError.unavailable("this device doesn't serve mlx now")) {
            try await gone.complete(Data("{}".utf8), timeout: 10)
        }
    }

    /// Done means this: a gateway lists both hosts of a peer that serves
    /// both, and sends each request to the one serving its model.
    @Test func aGatewayListsAndRoutesToBothHosts() async throws {
        let peer = try await TwoHostPeer()
        defer { peer.server.stop() }
        let gateway = Scheduler()
        let hosts = PeerHosts(endpointID: peerEndpoint, link: peer.link, scheduler: gateway)
        await hosts.start(every: .milliseconds(100))
        let ids = [RemoteHost.id(peerEndpoint), RemoteHost.id(peerEndpoint, ConfluxNode.appleHostID)]
        #expect(await eventually {
            let snapshot = await gateway.snapshot()
            return snapshot.hosts.map(\.id) == ids && snapshot.hosts.allSatisfy { $0.model != nil }
        })
        #expect(hosts.hosts.map(\.id) == ids)
        let models = await gateway.snapshot().hosts.map { $0.model?.id }
        #expect(models == ["model-a", AppleModelHost.modelID])

        for model in [AppleModelHost.modelID, "model-a"] {
            let outcome = await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: model, preference: nil),
                                               deadline: Date().addingTimeInterval(10), key: nil)
            guard case .completed(let reply, let ran) = outcome else {
                Issue.record("expected a completion on \(model), got \(outcome)")
                continue
            }
            #expect(reply.status == 200)
            #expect(ran.id == model)
        }
        #expect(peer.apple.calls == 1)
        #expect(peer.file.calls == 1)
        let served = await peer.scheduler.snapshot().hosts
        #expect(served.first { $0.id == ConfluxNode.appleHostID }?.completed == 1)

        await hosts.stop()
        #expect(await gateway.snapshot().hosts.isEmpty)
    }

    /// The peer's owner turns Apple's model off: its host leaves the
    /// gateway. On again, it's back.
    @Test func hostsFollowWhatThePeerLists() async throws {
        let peer = try await TwoHostPeer()
        defer { peer.server.stop() }
        let gateway = Scheduler()
        let hosts = PeerHosts(endpointID: peerEndpoint, link: peer.link, scheduler: gateway)
        await hosts.start(every: .milliseconds(100))
        defer { Task { await hosts.stop() } }
        #expect(await eventually { await gateway.snapshot().hosts.count == 2 })

        peer.serve([ConfluxNode.localHostID])
        #expect(await eventually { await gateway.snapshot().hosts.map(\.id) == [RemoteHost.id(peerEndpoint)] })
        #expect(hosts.hosts.count == 1)

        peer.serve([ConfluxNode.localHostID, ConfluxNode.appleHostID])
        #expect(await eventually { await gateway.snapshot().hosts.count == 2 })
    }

    /// A device serving only Apple's model answers for it by default, as it
    /// always has: one host, no others.
    @Test func appleAloneIsThePeersFirstHost() async throws {
        let peer = try await TwoHostPeer()
        defer { peer.server.stop() }
        peer.serve([ConfluxNode.appleHostID])
        let gateway = Scheduler()
        let hosts = PeerHosts(endpointID: peerEndpoint, link: peer.link, scheduler: gateway)
        await hosts.start(every: .milliseconds(100))
        #expect(await eventually { await gateway.snapshot().hosts.first?.model?.id == AppleModelHost.modelID })
        #expect(await gateway.snapshot().hosts.map(\.id) == [RemoteHost.id(peerEndpoint)])
        #expect(hosts.primary.otherHosts.isEmpty)
        await hosts.stop()
    }

    /// A peer running the protocol from before names no host and lists no
    /// others: it's one host, as before, and a host asked for by name there
    /// isn't taken for the peer's first.
    @Test func anOlderPeerIsOneHost() async throws {
        let older = Data("""
            {"protocol": 0, "availability": "available", "capacity": 1, "active": 0, "held": 0, "generation": 1,
             "model": {"id": "model-a", "fingerprint": "fake-model-a", "capabilities": ["text"]}}
            """.utf8)
        let server = HTTPServer(onlyFromThisProcess: true) { request in
            if request.path == HostProtocol.statusPath {
                return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: older)
            }
            return HTTPResponse(status: 404, headers: [], body: Data())
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let link = FixedLink(base: URL(string: "http://127.0.0.1:\(port)")!)

        let gateway = Scheduler()
        let hosts = PeerHosts(endpointID: peerEndpoint, link: link, scheduler: gateway)
        await hosts.start(every: .milliseconds(100))
        #expect(await eventually { await gateway.snapshot().hosts.first?.model?.id == "model-a" })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await gateway.snapshot().hosts.map(\.id) == [RemoteHost.id(peerEndpoint)])
        await hosts.stop()

        let named = RemoteHost(endpointID: peerEndpoint, link: link, hostOnPeer: ConfluxNode.appleHostID)
        await named.refresh()
        #expect(await named.availability == .offline)
        #expect(await named.model == nil)
        #expect(named.slots == 0)
    }

    /// What a gateway before this change sees of a device serving two
    /// hosts: its first, as before. The new fields are ones it ignores.
    @Test func anOlderGatewaySeesTheFirstHost() async throws {
        let peer = try await TwoHostPeer()
        defer { peer.server.stop() }
        let (data, _) = try await URLSession.shared.data(from: peer.base.appending(path: HostProtocol.statusPath))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? Int == 0)
        #expect((object["model"] as? [String: Any])?["id"] as? String == "model-a")
        #expect(object["host"] as? String == ConfluxNode.localHostID)
        #expect(object["hosts"] as? [String] == [ConfluxNode.localHostID, ConfluxNode.appleHostID])
    }
}
