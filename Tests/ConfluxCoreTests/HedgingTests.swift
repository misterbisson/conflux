import Foundation
import Testing
@testable import ConfluxCore

/// Hedging at the tail: a request that runs well past its host's typical
/// time gets a copy on an idle host when nothing waits. The first answer
/// wins, the other copy is cancelled, and the client sees one result.
@Suite struct HedgingTests {
    let any = ModelChoice(model: "any", preference: nil)

    /// Answers in 0.2 s the first time, then straggles on the second call.
    static func straggler(_ seconds: Double = 5) -> @Sendable (Int) async throws -> HostReply {
        { call in
            try await Task.sleep(for: .seconds(call == 1 ? 0.2 : seconds))
            return HostReply(status: 200, body: FakeHost.okBody)
        }
    }

    @Test func theFirstAnswerWinsAndTheOtherIsCancelled() async throws {
        let slow = FakeHost(id: "slow", behavior: Self.straggler())
        let quick = FakeHost(id: "quick", behavior: FakeHost.reply(after: 0.1))
        let scheduler = await Scheduler.with([slow, quick])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) // "slow" learns 0.2 s.
        let start = Date()
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        let elapsed = Date().timeIntervalSince(start)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        // Hedged at 2 x 0.2 s, answered 0.1 s later: not the 5 s straggle.
        #expect(elapsed > 0.4 && elapsed < 1.5, "answered after \(elapsed) s")
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedged == 1)
        #expect(snapshot.hedgeWins == 1)
        #expect(snapshot.completed == 2)
        let hosts = Dictionary(uniqueKeysWithValues: snapshot.hosts.map { ($0.id, $0) })
        // The straggling copy was cancelled: its slot is free, and it isn't
        // counted against the host.
        #expect(hosts["slow"]?.active == 0)
        #expect(hosts["slow"]?.failures.total == 0)
        #expect(hosts["slow"]?.completed == 1)
        #expect(hosts["quick"]?.completed == 1)
    }

    @Test func theFirstCopyCanStillWin() async throws {
        let slow = FakeHost(id: "slow", behavior: Self.straggler(0.6))
        let slower = FakeHost(id: "slower", behavior: FakeHost.reply(after: 3))
        let scheduler = await Scheduler.with([slow, slower])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        let start = Date()
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(Date().timeIntervalSince(start) < 1.5)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedged == 1)
        #expect(snapshot.hedgeWins == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await scheduler.snapshot().hosts.first { $0.id == "slower" }?.active == 0)
    }

    /// Work that waits, even for another model, means it isn't the tail.
    @Test func neverHedgesWhileWorkWaits() async throws {
        let slow = FakeHost(id: "slow", model: "model-a", behavior: Self.straggler(1))
        let idle = FakeHost(id: "idle", model: "model-b")
        let scheduler = await Scheduler.with([slow, idle])
        let onlyA = ModelChoice(model: "model-a", preference: nil)
        _ = await scheduler.submit(Data(), choice: onlyA, deadline: nil, key: nil)
        async let straggling = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        try await Task.sleep(for: .milliseconds(50))
        async let waiting = scheduler.submit(Data(), choice: onlyA, deadline: Date().addingTimeInterval(10), key: nil)
        let (first, second) = await (straggling, waiting)
        if case .completed = first {} else { Issue.record("\(first)") }
        if case .completed = second {} else { Issue.record("\(second)") }
        #expect(await scheduler.snapshot().hedged == 0)
        #expect(idle.callCount == 0)
    }

    /// A hedged copy gives its slot back as soon as work waits.
    @Test func hedgesGiveWayToWaitingWork() async throws {
        let slow = FakeHost(id: "slow", behavior: Self.straggler(1.5))
        let other = FakeHost(id: "other") { call in
            try await Task.sleep(for: .seconds(call == 1 ? 5 : 0.1))
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        let scheduler = await Scheduler.with([slow, other])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        async let straggling = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        try await Task.sleep(for: .milliseconds(600)) // Hedged onto "other" at 0.4 s.
        #expect(await scheduler.snapshot().hedged == 1)
        let start = Date()
        let late = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        if case .completed = late {} else { Issue.record("\(late)") }
        #expect(Date().timeIntervalSince(start) < 1, "waited \(Date().timeIntervalSince(start)) s")
        let first = await straggling
        if case .completed = first {} else { Issue.record("\(first)") }
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hedgeWins == 0)
        #expect(snapshot.hosts.allSatisfy { $0.failures.total == 0 })
    }

    @Test func noHedgingWhenTurnedOff() async throws {
        var config = SchedulerConfig()
        config.hedge = false
        let slow = FakeHost(id: "slow", behavior: Self.straggler(0.8))
        let quick = FakeHost(id: "quick")
        let scheduler = await Scheduler.with([slow, quick], config: config)
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        #expect(await scheduler.snapshot().hedged == 0)
        #expect(quick.callCount == 0)
    }

    /// The same key, hedged: the client gets one result, and a retry gets
    /// that same result.
    @Test func oneResultPerKey() async throws {
        let slow = FakeHost(id: "slow", behavior: Self.straggler())
        let quick = FakeHost(id: "quick", behavior: FakeHost.reply(after: 0.1))
        let scheduler = await Scheduler.with([slow, quick])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: "warm-up")
        async let a = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: "k")
        async let b = scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: "k")
        let (first, second) = await (a, b)
        #expect(first == second)
        #expect(await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") == first)
        #expect(await scheduler.snapshot().completed == 2)
    }
}

func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// Cancelling a copy on a host on another device.
@Suite struct CancelTests {
    @Test func aPeerStopsACancelledRequest() async throws {
        let peer = try await Peer(behavior: FakeHost.reply(after: 5))
        defer { peer.server.stop() }
        let id = UUID()
        async let running = attempt { try await peer.remote.complete(Data("{}".utf8), timeout: 10,
                                                                    options: RequestOptions(id: id)) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        await peer.remote.cancel(id)
        let result = await running
        #expect(Date().timeIntervalSince(start) < 1)
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
        let peer = try await Peer(behavior: FakeHost.reply(after: 0.5))
        defer { peer.server.stop() }
        _ = try await peer.remote.complete(Data("{}".utf8), timeout: 10) // Learns 0.5 s.
        async let running = peer.remote.complete(Data("{}".utf8), timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        let id = UUID()
        async let held = attempt { try await peer.remote.complete(Data("{}".utf8), timeout: 10,
                                                                 options: RequestOptions(id: id, prefetch: true)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await peer.scheduler.snapshot().hosts.first?.held == 1)
        await peer.remote.cancel(id)
        let heldResult = await held
        #expect(throws: HostError.cancelled) { try heldResult.get() }
        #expect(try await running.status == 200)
        #expect(peer.host.callCount == 2)
    }

    /// Across devices: the straggling peer is told to stop, and the client
    /// gets the idle peer's answer.
    @Test func hedgingAcrossPeers() async throws {
        let slow = try await Peer(endpoint: String(repeating: "aa", count: 32), behavior: HedgingTests.straggler())
        let quick = try await Peer(endpoint: String(repeating: "bb", count: 32), behavior: FakeHost.reply(after: 0.1))
        defer {
            slow.server.stop()
            quick.server.stop()
        }
        var config = SchedulerConfig()
        config.prefetch = false
        let gateway = Scheduler(config: config)
        await gateway.add(slow.remote)
        _ = await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: "any", preference: nil),
                                 deadline: nil, key: nil)
        await gateway.add(quick.remote)
        let start = Date()
        let outcome = await gateway.submit(Data("{}".utf8), choice: ModelChoice(model: "any", preference: nil),
                                           deadline: Date().addingTimeInterval(10), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(Date().timeIntervalSince(start) < 2)
        try await Task.sleep(for: .milliseconds(300))
        let host = try #require(await slow.scheduler.snapshot().hosts.first)
        #expect(host.active == 0, "the straggling copy should have stopped")
        #expect(host.failures.total == 0)
        let snapshot = await gateway.snapshot()
        #expect(snapshot.hedgeWins == 1)
        #expect(snapshot.hosts.allSatisfy { $0.failures.total == 0 })
        #expect(snapshot.hosts.allSatisfy { $0.active == 0 })
    }
}
