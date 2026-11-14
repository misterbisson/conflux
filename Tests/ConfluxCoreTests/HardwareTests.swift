import Foundation
import Testing
@testable import ConfluxCore

@Suite struct HardwareTests {
    static let m4Pro = HardwareInfo(chip: "Apple M4 Pro", performanceCores: 10, efficiencyCores: 4, gpuCores: 20,
                                    memoryBytes: 48 * 1_073_741_824, modelIdentifier: "Mac16,8")

    @Test func summaries() {
        #expect(Self.m4Pro.summary == "M4 Pro, 20-core GPU, 48 GB")
        #expect(Self.m4Pro.cpuCores == "14-core CPU (10 performance, 4 efficiency)")
        // An iPad, whose system doesn't count its GPU cores.
        let iPad = HardwareInfo(chip: "Apple M1", memoryBytes: 8_000_000_000, modelIdentifier: "iPad13,4")
        #expect(iPad.summary == "M1, 7 GB")
        #expect(iPad.cpuCores == nil)
        #expect(HardwareInfo(modelIdentifier: "iPad13,4").summary == "iPad13,4")
        #expect(HardwareInfo().summary == nil)
    }

    @Test func chipNames() {
        #expect(HardwareInfo.chip(fromBrand: "Apple M4 Pro") == "Apple M4 Pro")
        #expect(HardwareInfo.chip(fromBrand: "Apple processor") == nil)
        #expect(HardwareInfo.chip(fromBrand: "") == nil)
        #expect(HardwareInfo.chip(fromGPU: "Apple M1 GPU") == "Apple M1")
        #expect(HardwareInfo.chip(fromGPU: "Apple A17 Pro GPU") == "Apple A17 Pro")
        #expect(HardwareInfo.chip(fromGPU: "Apple M4 Pro") == "Apple M4 Pro")
        #expect(HardwareInfo.chip(fromGPU: "Apple GPU") == nil)
        #expect(HardwareInfo.chip(fromGPU: "AMD Radeon Pro") == nil)
    }

    /// Whatever this machine is, it reads something, and nothing that
    /// tells it from another of its kind: no hostname.
    @Test func readsThisDevice() {
        let current = HardwareInfo.current
        #expect(current.memoryBytes ?? 0 > 0)
        #expect(current.modelIdentifier != nil)
        let host = ProcessInfo.processInfo.hostName
        let encoded = String(decoding: try! JSONEncoder().encode(current), as: UTF8.self)
        #expect(host.isEmpty || !encoded.contains(host))
    }

    @Test func statusEncodesTheHardware() throws {
        let status = HostStatus(HostSnapshot(id: "local", state: .ready, slots: 1), hardware: Self.m4Pro)
        let data = try HostService.encoder.encode(status)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hardware = try #require(object["hardware"] as? [String: Any])
        #expect(hardware.keys.sorted() == ["chip", "efficiency_cores", "gpu_cores", "memory_bytes",
                                           "model_identifier", "performance_cores"])
        #expect(hardware["chip"] as? String == "Apple M4 Pro")
        #expect(hardware["gpu_cores"] as? Int == 20)
        #expect(hardware["memory_bytes"] as? Int == 48 * 1_073_741_824)
        #expect(hardware["model_identifier"] as? String == "Mac16,8")
        #expect(try HostService.decoder.decode(HostStatus.self, from: data).hardware == Self.m4Pro)
    }

    /// Fields the system didn't give are left out, not sent empty.
    @Test func statusLeavesOutWhatIsntKnown() throws {
        let iPad = HardwareInfo(chip: "Apple M1", memoryBytes: 8_000_000_000, modelIdentifier: "iPad13,4")
        let data = try HostService.encoder.encode(HostStatus(nil, hardware: iPad))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hardware = try #require(object["hardware"] as? [String: Any])
        #expect(hardware.keys.sorted() == ["chip", "memory_bytes", "model_identifier"])
    }

    /// A peer from before hardware was reported sends none, and still works.
    @Test func statusFromAnOlderPeer() throws {
        let older = """
            {"protocol": 0, "availability": "available", "capacity": 1, "active": 0, "held": 0, "generation": 3}
            """
        let status = try HostService.decoder.decode(HostStatus.self, from: Data(older.utf8))
        #expect(status.hardware == nil)
        #expect(status.hostAvailability == .available)
    }

    @Test func aPeerReportsItsHardware() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        #expect(peer.remote.hardware == HardwareInfo.current)
        let gateway = Scheduler()
        await gateway.add(peer.remote)
        #expect(await gateway.snapshot().hosts.first?.hardware == HardwareInfo.current)
    }

    @Test func anOlderPeerWithoutHardwareStillServes() async throws {
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
        let remote = RemoteHost(endpointID: String(repeating: "cd", count: 32),
                                link: FixedLink(base: URL(string: "http://127.0.0.1:\(port)")!))
        await remote.refresh()
        #expect(await remote.availability == .available)
        #expect(await remote.model?.id == "model-a")
        #expect(remote.hardware == nil)
        let gateway = Scheduler()
        await gateway.add(remote)
        let host = try #require(await gateway.snapshot().hosts.first)
        #expect(host.hardware == nil)
        #expect(Gateway.health(await gateway.snapshot())["hosts"].flatMap { $0 as? [[String: Any]] }?
            .first?["hardware"] == nil)
    }

    @Test func healthNamesEachHostsHardware() async throws {
        let snapshot = SchedulerSnapshot(
            hosts: [HostSnapshot(id: "local", state: .ready, perHour: 120, hardware: Self.m4Pro)],
            queued: 0, completed: 0, failures: FailureCounts(), rejected: 0, busy: 0, unavailable: 0, hedged: 0,
            hedgeWins: 0, perHour: 120, idleWithWorkSeconds: 0)
        let health = Gateway.health(snapshot)
        let body = try JSONSerialization.data(withJSONObject: health)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let host = try #require((object["hosts"] as? [[String: Any]])?.first)
        let hardware = try #require(host["hardware"] as? [String: Any])
        #expect(hardware["chip"] as? String == "Apple M4 Pro")
        #expect(hardware["gpu_cores"] as? Int == 20)
        #expect(hardware["performance_cores"] as? Int == 10)
        #expect(hardware["efficiency_cores"] as? Int == 4)
        #expect(hardware["memory_bytes"] as? Int == 48 * 1_073_741_824)
        #expect(hardware["model_identifier"] as? String == "Mac16,8")
    }
}
