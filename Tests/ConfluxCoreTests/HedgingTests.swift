import Foundation
import Testing
@testable import ConfluxCore

/// Hedging at the tail: a request that runs well past its host's typical
/// time gets a copy on an idle host when nothing waits. The first answer
/// wins, the other copy is cancelled, and the client sees one result.
///
/// Typical times are set, not measured, so when a request straggles doesn't
/// depend on how fast the machine running the tests is. The straggler's is
/// the shorter, so the request goes there first. Straggling hosts
/// take far longer than the copy, and tests wait on state, not for a time.
@Suite struct HedgingTests {
    let any = ModelChoice(model: "any", preference: nil)

    @Test func theFirstAnswerWinsAndTheOtherIsCancelled() async throws {
        let slow = FakeHost(id: "slow", behavior: FakeHost.reply(after: 30))
        let quick = FakeHost(id: "quick", behavior: FakeHost.reply(after: 0.1))
        let scheduler = await Scheduler.with([slow, quick])
        await scheduler.setTypical(0.1, for: "slow")
        await scheduler.setTypical(1, for: "quick")
        let start = Date()
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        // The copy's answer, not the 30 s straggler's.
        #expect(Date().timeIntervalSince(start) < 20)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedged == 1)
        #expect(snapshot.hedgeWins == 1)
        #expect(snapshot.completed == 1)
        // The straggling copy was cancelled: its slot frees, and it isn't
        // counted against the host.
        #expect(await eventually { await scheduler.snapshot().hosts.first { $0.id == "slow" }?.active == 0 })
        let hosts = Dictionary(uniqueKeysWithValues: await scheduler.snapshot().hosts.map { ($0.id, $0) })
        #expect(hosts["slow"]?.failures.total == 0)
        #expect(hosts["slow"]?.completed == 0)
        #expect(hosts["quick"]?.completed == 1)
    }

    @Test func theFirstCopyCanStillWin() async throws {
        let slow = FakeHost(id: "slow", behavior: FakeHost.reply(after: 2))
        let slower = FakeHost(id: "slower", behavior: FakeHost.reply(after: 30))
        let scheduler = await Scheduler.with([slow, slower])
        await scheduler.setTypical(0.1, for: "slow")
        await scheduler.setTypical(1, for: "slower")
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedged == 1)
        #expect(snapshot.hedgeWins == 0)
        #expect(await eventually { await scheduler.snapshot().hosts.first { $0.id == "slower" }?.active == 0 })
        #expect(await scheduler.snapshot().hosts.allSatisfy { $0.failures.total == 0 })
    }

    /// Work that waits, even for another model, means it isn't the tail.
    @Test func neverHedgesWhileWorkWaits() async throws {
        let slow = FakeHost(id: "slow", model: "model-a", behavior: FakeHost.reply(after: 3))
        let idle = FakeHost(id: "idle", model: "model-b")
        let scheduler = await Scheduler.with([slow, idle])
        await scheduler.setTypical(1, for: "slow") // Straggling after 2 s.
        await scheduler.setTypical(2, for: "idle")
        let onlyA = ModelChoice(model: "model-a", preference: nil)
        async let straggling = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: nil)
        #expect(await eventually { await scheduler.snapshot().hosts.first { $0.id == "slow" }?.active == 1 })
        async let waiting = scheduler.submit(Data(), choice: onlyA, deadline: Date().addingTimeInterval(60), key: nil)
        let (first, second) = await (straggling, waiting)
        if case .completed = first {} else { Issue.record("\(first)") }
        if case .completed = second {} else { Issue.record("\(second)") }
        #expect(await scheduler.snapshot().hedged == 0)
        #expect(idle.callCount == 0)
    }

    /// A hedged copy gives its slot back as soon as work waits.
    @Test func hedgesGiveWayToWaitingWork() async throws {
        let slow = FakeHost(id: "slow", behavior: FakeHost.reply(after: 5))
        let other = FakeHost(id: "other") { call in
            // The copy would take 30 s; the request after it, 0.1 s.
            try await Task.sleep(for: .seconds(call == 1 ? 30 : 0.1))
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        let scheduler = await Scheduler.with([slow, other])
        await scheduler.setTypical(0.1, for: "slow")
        await scheduler.setTypical(1, for: "other")
        async let straggling = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: nil)
        #expect(await eventually { await scheduler.snapshot().hedged == 1 })
        let late = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: nil)
        if case .completed = late {} else { Issue.record("\(late)") }
        // It ran on the copy's slot, while the straggler still ran.
        #expect(other.callCount == 2)
        #expect(await scheduler.snapshot().hosts.first { $0.id == "slow" }?.active == 1)
        let first = await straggling
        if case .completed = first {} else { Issue.record("\(first)") }
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedgeWins == 0)
        #expect(snapshot.hosts.allSatisfy { $0.failures.total == 0 })
    }

    @Test func noHedgingWhenTurnedOff() async throws {
        var config = SchedulerConfig()
        config.hedge = false
        let slow = FakeHost(id: "slow", behavior: FakeHost.reply(after: 0.8))
        let quick = FakeHost(id: "quick")
        let scheduler = await Scheduler.with([slow, quick], config: config)
        await scheduler.setTypical(0.1, for: "slow")
        await scheduler.setTypical(1, for: "quick")
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        #expect(await scheduler.snapshot().hedged == 0)
        #expect(quick.callCount == 0)
    }

    /// The same key, hedged: the client gets one result, and a retry gets
    /// that same result.
    @Test func oneResultPerKey() async throws {
        let slow = FakeHost(id: "slow", behavior: FakeHost.reply(after: 30))
        let quick = FakeHost(id: "quick", behavior: FakeHost.reply(after: 0.1))
        let scheduler = await Scheduler.with([slow, quick])
        await scheduler.setTypical(0.1, for: "slow")
        await scheduler.setTypical(1, for: "quick")
        async let a = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: "k")
        async let b = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(60), key: "k")
        let (first, second) = await (a, b)
        #expect(first == second)
        #expect(await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") == first)
        #expect(await scheduler.snapshot().completed == 1)
        #expect(await scheduler.snapshot().hedgeWins == 1)
    }
}

func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// Cancelling a copy on a host on another device.
@Suite struct CancelTests {
    @Test func aPeerStopsACancelledRequest() async throws {
        let peer = try await Peer(behavior: FakeHost.reply(after: 30))
        defer { peer.server.stop() }
        let id = UUID()
        async let running = attempt { try await peer.remote.complete(Data("{}".utf8), timeout: 60,
                                                                    options: RequestOptions(id: id)) }
        #expect(await eventually { await peer.scheduler.snapshot().hosts.first?.active == 1 })
        let start = Date()
        await peer.remote.cancel(id)
        let result = await running
        // Stopped, not run out: the request would take 30 s.
        #expect(Date().timeIntervalSince(start) < 20)
        #expect(throws: HostError.cancelled) { try result.get() }
        let host = try #require(await peer.scheduler.snapshot().hosts.first)
        #expect(host.active == 0)
        #expect(host.failures.total == 0)
    }

    @Test func aCancelThatArrivesFirstStillCounts() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        let id = UUID()
        await peer.remote.cancel(id)
        await #expect(throws: HostError.cancelled) {
            try await peer.remote.complete(Data("{}".utf8), timeout: 10, options: RequestOptions(id: id))
        }
        #expect(peer.host.callCount == 0)
    }

    @Test func aHeldRequestCanBeCancelled() async throws {
        // The first request runs until the held one has been cancelled.
        let gate = Gate()
        let peer = try await Peer(behavior: gate.reply())
        defer { peer.server.stop() }
        await peer.scheduler.setTypical(1, for: "local")
        async let running = peer.remote.complete(Data("{}".utf8), timeout: 30)
        #expect(await eventually { await peer.scheduler.snapshot().hosts.first?.active == 1 })
        let id = UUID()
        async let held = attempt { try await peer.remote.complete(Data("{}".utf8), timeout: 30,
                                                                 options: RequestOptions(id: id, prefetch: true)) }
        #expect(await eventually { await peer.scheduler.snapshot().hosts.first?.held == 1 })
        await peer.remote.cancel(id)
        let heldResult = await held
        #expect(throws: HostError.cancelled) { try heldResult.get() }
        await gate.release()
        #expect(try await running.status == 200)
        #expect(peer.host.callCount == 1)
    }

    /// Across devices: the straggling peer is told to stop, and the client
    /// gets the idle peer's answer.
    @Test func hedgingAcrossPeers() async throws {
        let slow = try await Peer(endpoint: String(repeating: "aa", count: 32), behavior: FakeHost.reply(after: 30))
        let quick = try await Peer(endpoint: String(repeating: "bb", count: 32), behavior: FakeHost.reply(after: 0.1))
        defer {
            slow.server.stop()
            quick.server.stop()
        }
        var config = SchedulerConfig()
        config.prefetch = false
        let gateway = Scheduler(config: config)
        await gateway.add(slow.remote)
        await gateway.add(quick.remote)
        await gateway.setTypical(0.1, for: slow.remote.id)
        await gateway.setTypical(1, for: quick.remote.id)
        let outcome = await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: "any", preference: nil),
                                           deadline: Date().addingTimeInterval(60), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(await gateway.snapshot().hedgeWins == 1)
        #expect(await eventually { await slow.scheduler.snapshot().hosts.first?.active == 0 },
                "the straggling copy should have stopped")
        #expect(await slow.scheduler.snapshot().hosts.first?.failures.total == 0)
        #expect(await eventually { await gateway.snapshot().hosts.allSatisfy { $0.active == 0 } })
        #expect(await gateway.snapshot().hosts.allSatisfy { $0.failures.total == 0 })
    }
}
