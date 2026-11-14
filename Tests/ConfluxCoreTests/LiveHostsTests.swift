import Foundation
import Testing
@testable import ConfluxCore

/// Turning a model off while serving, as cutting its slots does: it takes
/// nothing new, and goes once what it runs has finished, or at once, each
/// request going to another host.
@Suite struct LiveHostsTests {
    let any = ModelChoice(model: "any", preference: nil)

    @Test func aRetiredHostFinishesWhatItRunsFirst() async {
        let gate = Gate()
        let leaving = FakeHost(id: "apple", model: "apple-on-device", behavior: gate.reply())
        let staying = FakeHost(id: "local", model: "model-b", slots: 2)
        // No copy of the slow request on the idle host: this is about the one running.
        var config = SchedulerConfig()
        config.hedge = false
        let scheduler = await Scheduler.with([leaving, staying], config: config)
        await scheduler.setTypical(0.01, for: "apple")
        await scheduler.setTypical(1, for: "local")
        let first = Task { await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil) }
        #expect(await eventually { leaving.callCount == 1 })

        let retiring = Task { await scheduler.retire(hostID: "apple", cancelling: false) }
        #expect(await eventually { await scheduler.snapshot().hosts.first { $0.id == "apple" }?.state == .draining })
        // Nothing new goes to it while it finishes.
        let second = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        guard case .completed(_, let model) = second else {
            Issue.record("\(second)")
            return
        }
        #expect(model.id == "model-b")
        #expect(leaving.callCount == 1)

        await gate.release()
        await retiring.value
        guard case .completed(_, let firstModel) = await first.value else {
            Issue.record("the running request should have finished")
            return
        }
        #expect(firstModel.id == "apple-on-device")
        #expect(await scheduler.snapshot().hosts.map(\.id) == ["local"])
    }

    @Test func cancellingSendsWhatItRunsElsewhere() async {
        let leaving = FakeHost(id: "local", model: "model-a", behavior: FakeHost.reply(after: 30))
        let staying = FakeHost(id: "apple", model: "apple-on-device")
        let scheduler = await Scheduler.with([leaving, staying])
        await scheduler.setTypical(0.01, for: "local")
        await scheduler.setTypical(1, for: "apple")
        let request = Task { await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(20), key: nil) }
        #expect(await eventually { leaving.callCount == 1 })

        let started = Date()
        await scheduler.retire(hostID: "local", cancelling: true)
        #expect(Date().timeIntervalSince(started) < 10)
        guard case .completed(_, let model) = await request.value else {
            Issue.record("the request should have gone to the other host")
            return
        }
        #expect(model.id == "apple-on-device")
        #expect(staying.callCount == 1)
        #expect(await scheduler.snapshot().hosts.map(\.id) == ["apple"])
    }

    @Test func retiringAnIdleHostRemovesItAtOnce() async {
        let host = FakeHost(id: "apple", model: "apple-on-device")
        let scheduler = await Scheduler.with([host])
        await scheduler.retire(hostID: "apple", cancelling: false)
        #expect(await scheduler.snapshot().hosts.isEmpty)
        // A host it doesn't have is nothing to do.
        await scheduler.retire(hostID: "nowhere", cancelling: true)
    }

    /// Peers' gateways read the hosts in each status, so a change shows at
    /// the next one.
    @Test func theHostServiceTellsPeersWhatItServesNow() async throws {
        let scheduler = await Scheduler.with([FakeHost(id: "local"), FakeHost(id: "apple", model: "apple-on-device")])
        let service = HostService(scheduler: scheduler, hostIDs: ["local", "apple"], files: [.model: "/models/a.gguf"])
        func status() async throws -> HostStatus {
            let response = await service.handle(HTTPRequest(method: "GET", path: HostProtocol.statusPath))
            return try JSONDecoder().decode(HostStatus.self, from: response.body)
        }
        #expect(try await status().hosts == ["local", "apple"])
        service.update(hostIDs: ["apple"], files: [:])
        let now = try await status()
        #expect(now.hosts == ["apple"])
        #expect(now.host == "apple")
        #expect(service.files.isEmpty)
    }

    @Test func settingsSavedBeforeTheSwitchServeTheModelFile() throws {
        let old = #"{"port":8090,"requireToken":true,"peers":[],"iCloudKeychain":true}"#
        let settings = try JSONDecoder().decode(NodeSettings.self, from: Data(old.utf8))
        #expect(settings.servesModelFile)
        var off = settings
        off.servesModelFile = false
        let again = try JSONDecoder().decode(NodeSettings.self, from: JSONEncoder().encode(off))
        #expect(!again.servesModelFile)
    }
}

/// The node turning Apple's real model off and on while it runs. Set
/// CONFLUX_TEST_APPLE_MODEL=1 on a Mac with Apple Intelligence turned on.
@Suite struct LiveAppleModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONFLUX_TEST_APPLE_MODEL"] != nil))
    func turnsAppleModelOffAndOnWhileRunning() async throws {
        let node = ConfluxNode()
        try await node.start(NodeSettings(port: 0, requireToken: false, iCloudKeychain: false,
                                          appleModel: AppleModelSettings(enabled: true, selfCheck: false),
                                          gateway: false))
        func hosts() async -> [String] { await node.scheduler.snapshot().hosts.map(\.id) }
        #expect(await hosts() == [ConfluxNode.appleHostID])
        await node.setAppleModel(nil)
        #expect(await hosts().isEmpty)
        await node.setAppleModel(AppleModelSettings(enabled: true, selfCheck: false))
        #expect(await hosts() == [ConfluxNode.appleHostID])
        #expect(await eventually(within: 30) {
            await node.scheduler.snapshot().hosts.first?.state == .ready
        })
        await node.stop()
    }
}
