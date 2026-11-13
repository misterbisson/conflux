import Foundation
import Testing
@testable import ConfluxCore

/// A link to a host service on loopback, without iroh.
struct FixedLink: PeerLink {
    let base: URL
    func url() async throws -> URL { base }
    func reconnect() {}
    var problem: String? { get async { nil } }
    var connected: Bool { get async { true } }
}

/// A host on "another device": a scheduler with a fake host behind a host
/// service on loopback, which a RemoteHost reaches with a FixedLink.
struct Peer {
    let host: FakeHost
    let scheduler: Scheduler
    let server: HTTPServer
    let remote: RemoteHost
    let base: URL

    /// `latency` is added each way to every exchange, like a network.
    init(slots: Int = 1, latency: Duration = .zero, endpoint: String = String(repeating: "ab", count: 32),
         behavior: @escaping @Sendable (Int) async throws -> HostReply = FakeHost.reply(after: 0)) async throws {
        host = FakeHost(id: "local", slots: slots, behavior: behavior)
        scheduler = await Scheduler.with([host])
        let service = HostService(scheduler: scheduler, hostID: "local")
        server = HTTPServer(onlyFromThisProcess: true) { request in
            if latency > .zero { try? await Task.sleep(for: latency) }
            let response = await service.handle(request)
            if latency > .zero { try? await Task.sleep(for: latency) }
            return response
        }
        let port = try await server.start(port: 0)
        base = URL(string: "http://127.0.0.1:\(port)")!
        remote = RemoteHost(endpointID: endpoint, link: FixedLink(base: base))
        await remote.refresh()
    }

    /// Another gateway's view of the same host.
    func anotherRemote() async -> RemoteHost {
        let remote = RemoteHost(endpointID: String(repeating: "ef", count: 32), link: FixedLink(base: base))
        await remote.refresh()
        return remote
    }
}

@Suite struct DeviceIdentityTests {
    @Test func endpointIDs() {
        let identity = DeviceIdentity.ephemeral()
        #expect(DeviceIdentity.isEndpointID(identity.endpointID))
        #expect(identity != DeviceIdentity.ephemeral())
        #expect(!DeviceIdentity.isEndpointID(identity.endpointID.uppercased()))
        #expect(!DeviceIdentity.isEndpointID(String(identity.endpointID.dropLast())))
        #expect(DeviceIdentity.short(identity.endpointID).count == 10)
    }

    @Test func savedSettingsWithoutPeersLoad() throws {
        let old = #"{"port":8090,"requireToken":true}"#
        let settings = try JSONDecoder().decode(NodeSettings.self, from: Data(old.utf8))
        #expect(settings.peers.isEmpty)
        #expect(settings.host == nil)
        #expect(settings.gateway)
    }
}

/// The endpoint is global to the process, so these run one at a time.
@Suite(.serialized) struct MeshEndpointTests {
    /// conflux derives the endpoint ID from the key itself, to show it without
    /// starting iroh. iroh has to agree.
    @Test func irohAgreesOnTheEndpointID() throws {
        let identity = DeviceIdentity.ephemeral()
        let mesh = try Mesh(identity: identity, peers: [], exposing: nil)
        defer { mesh.stop() }
        #expect(Iroh.endpointID == identity.endpointID)
        #expect(throws: MeshError.self) { try Mesh(identity: identity, peers: [], exposing: nil) }
    }

    @Test func noPeersStartsNothing() async throws {
        let node = ConfluxNode()
        let port = try await node.start(NodeSettings(port: 0, requireToken: false),
                                        identity: try { () throws -> DeviceIdentity in throw MeshFailure(description: "not asked") }(),
                                        tokenURL: FileManager.default.temporaryDirectory.appending(path: "conflux-token-\(UUID())"))
        defer { Task { await node.stop() } }
        #expect(port > 0)
        #expect(node.meshProblem == nil)
        #expect(node.peers.isEmpty)
    }

    /// Listed devices are peers. One listed while running joins the running
    /// mesh; one forgotten leaves it; an unreadable directory keeps what it
    /// had.
    @Test func directoryPeersJoinAndLeave() async throws {
        let me = DeviceIdentity.ephemeral()
        let (a, b) = (DeviceIdentity.ephemeral().endpointID, DeviceIdentity.ephemeral().endpointID)
        let directory = MemoryDeviceDirectory([ListedDevice(endpointID: me.endpointID, name: "me"),
                                               ListedDevice(endpointID: a, name: "A")])
        let node = ConfluxNode()
        try await node.start(NodeSettings(port: 0, requireToken: false), identity: me, directory: directory)
        #expect(node.meshProblem == nil)
        #expect(Iroh.endpointID == me.endpointID)
        #expect(node.peers.map(\.endpointID) == [a])
        #expect(node.trustedPeers == [TrustedPeer(endpointID: a, name: "A")])

        try directory.publish(ListedDevice(endpointID: b, name: "B"))
        await node.refreshPeers()
        #expect(Set(node.peers.map(\.endpointID)) == [a, b])
        #expect(node.meshProblem == nil)

        try directory.remove(a)
        await node.refreshPeers()
        #expect(node.peers.map(\.endpointID) == [b])
        #expect(node.meshProblem == nil)

        directory.failure = MeshFailure(description: "locked")
        await node.refreshPeers()
        #expect(node.peers.map(\.endpointID) == [b])
        #expect(node.directoryProblem == "locked")

        directory.failure = nil
        try directory.remove(b)
        await node.refreshPeers()
        #expect(node.peers.isEmpty)
        #expect(Iroh.endpointID == nil)

        await node.stop()
        #expect(node.trustedPeers.isEmpty)
    }

    /// An iPad runs no gateway, and uses no peer's host: it only serves its
    /// own. Its peers are still trusted, so their gateways can reach it.
    @Test func aHostOnlyNodeRunsNoGateway() async throws {
        let me = DeviceIdentity.ephemeral()
        let mac = DeviceIdentity.ephemeral().endpointID
        let directory = MemoryDeviceDirectory([ListedDevice(endpointID: mac, name: "Mac")])
        let node = ConfluxNode()
        let port = try await node.start(NodeSettings(port: 0, requireToken: false, gateway: false), identity: me,
                                        directory: directory)
        #expect(port == 0)
        #expect(node.port == nil)
        #expect(node.meshProblem == nil)
        #expect(node.peers.map(\.endpointID) == [mac])
        #expect(node.peers.first?.hostID == "")
        #expect(await node.scheduler.snapshot().hosts.isEmpty)

        // Reading the directory again keeps the mesh it has.
        await node.refreshPeers()
        #expect(node.peers.map(\.endpointID) == [mac])
        #expect(await node.scheduler.snapshot().hosts.isEmpty)
        await node.stop()
    }

    /// Hand-added and listed together, each once.
    @Test func handAddedPeersAndTheDirectory() async throws {
        let me = DeviceIdentity.ephemeral()
        let (a, b) = (DeviceIdentity.ephemeral().endpointID, DeviceIdentity.ephemeral().endpointID)
        let directory = MemoryDeviceDirectory([ListedDevice(endpointID: a, name: "A")])
        let node = ConfluxNode()
        try await node.start(NodeSettings(port: 0, requireToken: false, peers: [a, b]), identity: me,
                             directory: directory)
        #expect(Set(node.peers.map(\.endpointID)) == [a, b])
        #expect(node.trustedPeers.first { $0.endpointID == a } == TrustedPeer(endpointID: a, name: "A", addedByHand: true))

        // Forgotten, but still added by hand: still a peer.
        try directory.remove(a)
        await node.refreshPeers()
        #expect(Set(node.peers.map(\.endpointID)) == [a, b])
        await node.stop()
    }

    /// Turned off, the directory isn't read, and with no hand-added peers
    /// nothing starts: not even the key is needed.
    @Test func directoryOff() async throws {
        let directory = MemoryDeviceDirectory([ListedDevice(endpointID: DeviceIdentity.ephemeral().endpointID, name: "A")])
        directory.failure = MeshFailure(description: "not asked")
        let node = ConfluxNode()
        try await node.start(NodeSettings(port: 0, requireToken: false, iCloudKeychain: false),
                             identity: try { () throws -> DeviceIdentity in throw MeshFailure(description: "not asked") }(),
                             directory: directory)
        #expect(node.meshProblem == nil)
        #expect(node.directoryProblem == nil)
        #expect(node.peers.isEmpty)
        #expect(Iroh.endpointID == nil)
        await node.stop()
    }

    /// A directory listing only this device starts no endpoint.
    @Test func aDirectoryOfOneStartsNothing() async throws {
        let me = DeviceIdentity.ephemeral()
        let node = ConfluxNode()
        try await node.start(NodeSettings(port: 0, requireToken: false), identity: me,
                             directory: MemoryDeviceDirectory([ListedDevice(endpointID: me.endpointID, name: "me")]))
        #expect(node.meshProblem == nil)
        #expect(node.peers.isEmpty)
        #expect(Iroh.endpointID == nil)
        await node.stop()
    }
}

@Suite struct RemoteHostTests {
    @Test func readsThePeersHost() async throws {
        let peer = try await Peer(slots: 2)
        defer { peer.server.stop() }
        #expect(await peer.remote.availability == .available)
        #expect(await peer.remote.model?.id == "model-a")
        #expect(peer.remote.slots == 2)
    }

    @Test func completesAndNamesTheModel() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        let reply = try await peer.remote.complete(Data("{}".utf8), timeout: 10)
        #expect(reply.status == 200)
        #expect(reply.model?.fingerprint == "fake-model-a")
        let object = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
        #expect(object?["system_fingerprint"] as? String == "fake-model-a")
    }

    @Test func rejectionsPassThrough() async throws {
        let peer = try await Peer(behavior: FakeHost.reply(after: 0, status: 400, body: Data(#"{"error":{}}"#.utf8)))
        defer { peer.server.stop() }
        let reply = try await peer.remote.complete(Data("{}".utf8), timeout: 10)
        #expect(reply.status == 400)
        // Passed on, naming the model that refused.
        #expect(reply.model?.id == "model-a")
        let object = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
        #expect(object?["error"] != nil)
        #expect(object?["system_fingerprint"] as? String == "fake-model-a")
    }

    /// The peer admits work: a request without a free slot is refused, and
    /// the gateway's scheduler tries another host instead of counting a
    /// failure.
    @Test func aFullPeerSaysBusy() async throws {
        // The first request holds the slot until the second is refused,
        // however slow the runner.
        let gate = Gate()
        let peer = try await Peer(behavior: gate.reply())
        defer { peer.server.stop() }
        async let first = peer.remote.complete(Data("{}".utf8), timeout: 30)
        #expect(await eventually { await peer.scheduler.snapshot().hosts.first?.active == 1 })
        await #expect(throws: HostError.busy("the peer has no free slot")) {
            try await peer.remote.complete(Data("{}".utf8), timeout: 10)
        }
        await gate.release()
        #expect(try await first.status == 200)
    }

    @Test func gatewaySchedulesToThePeer() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        let gateway = Scheduler()
        await gateway.add(peer.remote)
        let outcome = await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: "any", preference: nil),
                                           deadline: Date().addingTimeInterval(10), key: nil)
        guard case .completed(let reply, let model) = outcome else {
            Issue.record("expected a completion, got \(outcome)")
            return
        }
        #expect(reply.status == 200)
        #expect(model.fingerprint == "fake-model-a")
        // Served for a peer: the host counts it, the host's own gateway doesn't.
        let served = await peer.scheduler.snapshot()
        #expect(served.hosts.first?.completed == 1)
        #expect(served.completed == 0)
    }

    @Test func reportsItsFreeTime() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        await peer.remote.refresh()
        let report = try #require(await peer.remote.report)
        #expect(try #require(report.freeSeconds) >= 0.15)
        #expect(abs(report.at.timeIntervalSinceNow) < 1)
        #expect(report.free == 1)
        #expect(report.pulls)
    }

    /// The yardstick for host pull: a gateway that sends work only once a
    /// request comes back leaves a peer's slot free for a round trip each
    /// time. The peer counts that free time, and the gateway counts it as
    /// idle with work while more work waited. (Sending a request ahead
    /// closes the gap: `HostPullTests`.)
    @Test func measuresAPeersIdleTimeWhileWorkWaits() async throws {
        let peer = try await Peer(latency: .milliseconds(40), behavior: FakeHost.reply(after: 0.1))
        defer { peer.server.stop() }
        var config = SchedulerConfig()
        config.prefetch = false
        let gateway = Scheduler(config: config)
        await gateway.add(peer.remote)
        peer.remote.start(every: .milliseconds(100))
        await gateway.startRefreshing(every: .milliseconds(100))
        defer { peer.remote.stop() }
        let deadline = Date().addingTimeInterval(20)
        let began = Date()
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: "any", preference: nil),
                                         deadline: deadline, key: nil)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let ran = Date().timeIntervalSince(began)
        try await Task.sleep(for: .milliseconds(300))
        await gateway.stopRefreshing()
        #expect(outcomes.allSatisfy { if case .completed = $0 { true } else { false } })
        let snapshot = await gateway.snapshot()
        let host = try #require(snapshot.hosts.first)
        // Eleven gaps of at least a round trip (80 ms), less what the status
        // poll's granularity loses at the edges.
        #expect(host.idleWithWorkSeconds > 0.5, "idle with work \(host.idleWithWorkSeconds) s")
        // Work waited for only part of the run, and a slow runner stretches
        // the run, so the run's own length is the bound.
        #expect(host.idleWithWorkSeconds < ran, "idle with work \(host.idleWithWorkSeconds) s in a \(ran) s run")
        #expect(snapshot.idleWithWorkSeconds == host.idleWithWorkSeconds)
        #expect(host.completed == 12)
        #expect(host.perHour == 72)
    }

    @Test func aSilentPeerIsLost() async throws {
        let peer = try await Peer()
        #expect(await peer.remote.availability == .available)
        peer.server.stop()
        for _ in 0..<RemoteHost.missesBeforeLost { await peer.remote.refresh() }
        #expect(await peer.remote.availability == .starting("the peer isn't answering"))
        #expect(await peer.remote.model == nil)
        await #expect(throws: HostError.self) { try await peer.remote.complete(Data("{}".utf8), timeout: 2) }
    }

    @Test func aPeerWithoutAModel() async throws {
        let scheduler = Scheduler()
        let service = HostService(scheduler: scheduler, hostID: nil)
        let server = HTTPServer(onlyFromThisProcess: true) { request in await service.handle(request) }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let remote = RemoteHost(endpointID: String(repeating: "cd", count: 32),
                                link: FixedLink(base: URL(string: "http://127.0.0.1:\(port)")!))
        await remote.refresh()
        #expect(await remote.availability == .offline)
        #expect(await remote.model == nil)
    }
}

/// Runs curl, with a 3-second limit, and returns what it wrote. It waits
/// without holding a thread: blocked in `waitUntilExit()`, a test can starve
/// the few threads a CI runner has, so the server curl is calling never
/// answers.
private func curl(_ arguments: [String]) async throws -> Data {
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-s", "-m", "3"] + arguments
    let output = Pipe()
    curl.standardOutput = output
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
        curl.terminationHandler = { _ in done.resume() }
        do {
            try curl.run()
        } catch {
            curl.terminationHandler = nil
            done.resume(throwing: error)
        }
    }
    return output.fileHandleForReading.readDataToEndOfFile()
}

@Suite struct HostServiceTests {
    /// The host service has no token, so it takes connections only from this
    /// process, where apple-iroh opens them.
    @Test func refusesOtherProcesses() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        let base = try await peer.remote.link.url()
        let code = String(decoding: try await curl(["-o", "/dev/null", "-w", "%{http_code}",
                                                    base.appending(path: HostProtocol.statusPath).absoluteString]),
                          as: UTF8.self)
        #expect(code == "000")
        // This process still gets in.
        #expect(await peer.remote.availability == .available)
    }

    /// On iPadOS the host service listens on a Unix socket in the app's
    /// container, and anything that reaches the socket gets in.
    @Test func answersOverAUnixSocket() async throws {
        let scheduler = await Scheduler.with([FakeHost(id: "local")])
        let service = HostService(scheduler: scheduler, hostID: "local")
        let server = HTTPServer(onlyFromThisProcess: false) { request in await service.handle(request) }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("conflux-test-\(getpid()).sock")
        // A file left by an earlier run is replaced.
        FileManager.default.createFile(atPath: path, contents: Data())
        try await server.start(socket: path)
        let status = try HostService.decoder.decode(
            HostStatus.self, from: try await curl(["--unix-socket", path, "http://host\(HostProtocol.statusPath)"]))
        #expect(status.availability == "available")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func runOnHostDoesntQueue() async throws {
        let host = FakeHost(id: "local", behavior: FakeHost.reply(after: 1))
        let scheduler = await Scheduler.with([host])
        async let first = scheduler.run(Data("{}".utf8), onHost: "local", deadline: nil)
        while await scheduler.snapshot().hosts.first?.active == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let second = await scheduler.run(Data("{}".utf8), onHost: "local", deadline: nil)
        guard case .busy = second else {
            Issue.record("expected busy, got \(second)")
            return
        }
        guard case .completed = await first else {
            Issue.record("expected the first to complete")
            return
        }
        #expect(await scheduler.run(Data("{}".utf8), onHost: "nobody", deadline: nil)
            == .unavailable(retryAfter: 30, message: "this device isn't serving a model"))
    }

    @Test func statusFollowsTheHostsState() {
        let snapshot = HostSnapshot(id: "local", state: .paused("paused by its owner"), slots: 1, freeSeconds: 2.5)
        let status = HostStatus(snapshot)
        #expect(status.freeSeconds == 2.5)
        #expect(status.hostAvailability == .paused("paused by its owner"))
        #expect(HostStatus(nil).hostAvailability == .offline)
    }
}
