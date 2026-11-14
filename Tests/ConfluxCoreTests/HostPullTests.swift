import Foundation
import Testing
@testable import ConfluxCore

/// Host pull: a host says the moment a slot frees up, gateways that lose a
/// slot to another gateway wait for the next one, and fast hosts take one
/// request ahead.
@Suite struct HostPullTests {
    let any = ModelChoice(model: "any", preference: nil)

    @Test func statusAnswersWhenASlotFrees() async throws {
        // The request runs until the test lets it finish: a slow runner can't
        // free the slot before the test has seen it taken.
        let gate = Gate()
        let peer = try await Peer(behavior: gate.reply())
        defer { peer.server.stop() }
        let running = Task { await peer.scheduler.run(Data("{}".utf8), onHost: "local", deadline: nil) }
        #expect(await eventually { await peer.scheduler.snapshot().hosts.first?.active == 1 })
        await peer.remote.refresh()
        #expect(await peer.remote.report?.free == 0)
        // Held until the slot frees, well before the 5 s wait is up.
        let start = Date()
        let held = Task { await peer.remote.refresh(waitingUpTo: 5) }
        try await Task.sleep(for: .milliseconds(200))
        await gate.release()
        #expect(await held.value)
        let waited = Date().timeIntervalSince(start)
        #expect(waited < 4.5, "answered after \(waited) s")
        #expect(await peer.remote.report?.free == 1)
        _ = await running.value

        // Nothing changing: answered after the wait, unchanged.
        let quiet = Date()
        #expect(await peer.remote.refresh(waitingUpTo: 0.3))
        #expect(Date().timeIntervalSince(quiet) >= 0.25)
    }

    @Test func completionsSayHowTheSlotsStand() async throws {
        let peer = try await Peer(slots: 2, behavior: FakeHost.reply(after: 0.2))
        defer { peer.server.stop() }
        let gateway = Scheduler()
        await gateway.add(peer.remote)
        async let first = gateway.submit(Data("{}".utf8), choice: any, deadline: Date().addingTimeInterval(5), key: nil)
        try await Task.sleep(for: .milliseconds(50))
        _ = await gateway.submit(Data("{}".utf8), choice: any, deadline: Date().addingTimeInterval(5), key: nil)
        // The second answer came back after the first: no status was asked
        // for since the start, yet the gateway knows both slots are free.
        _ = await first
        let report = try #require(await peer.remote.report)
        #expect(report.free == 2)
        #expect(await gateway.snapshot().hosts.first?.state == .ready)
    }

    /// Two gateways share one host's slot. One that loses it waits for the
    /// host to say it's free again, rather than answering 429.
    @Test func gatewaysSharingAHostTakeTurns() async throws {
        let peer = try await Peer(behavior: FakeHost.reply(after: 0.15))
        defer { peer.server.stop() }
        let other = await peer.anotherRemote()
        let a = Scheduler(), b = Scheduler()
        await a.add(peer.remote)
        await b.add(other)
        peer.remote.start()
        other.start()
        defer {
            peer.remote.stop()
            other.stop()
        }
        let deadline = Date().addingTimeInterval(10)
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for gateway in [a, b] {
                for _ in 0..<4 {
                    group.addTask { await gateway.submit(Data("{}".utf8), choice: any, deadline: deadline, key: nil) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { if case .completed = $0 { true } else { false } }, "\(outcomes)")
        #expect(peer.host.callCount == 8)
        #expect(peer.host.peakConcurrency == 1)
        // The gateways still race when a slot frees, and the one that loses
        // is refused, but it waits for the next slot instead of answering 429.
        #expect(await a.snapshot().busy == 0)
        #expect(await b.snapshot().busy == 0)
    }

    @Test func aHostHoldsOneRequestSentAhead() async throws {
        // The first request runs until the test has seen the others refused.
        let gate = Gate()
        let host = FakeHost(id: "local", behavior: gate.reply())
        let scheduler = await Scheduler.with([host])
        await scheduler.setTypical(0.5, for: "local")
        let deadline = Date().addingTimeInterval(30)
        async let running = scheduler.run(Data(), onHost: "local", deadline: deadline)
        #expect(await eventually { await scheduler.snapshot().hosts.first?.active == 1 })
        async let ahead = scheduler.run(Data(), onHost: "local", deadline: deadline, prefetch: true)
        #expect(await eventually { await scheduler.snapshot().hosts.first?.held == 1 })
        // One held is all: another sent ahead, or one not sent ahead, is refused.
        let second = await scheduler.run(Data(), onHost: "local", deadline: deadline, prefetch: true)
        if case .busy = second {} else { Issue.record("\(second)") }
        let plain = await scheduler.run(Data(), onHost: "local", deadline: deadline)
        if case .busy = plain {} else { Issue.record("\(plain)") }
        await gate.release()
        let (first, held) = await (running, ahead)
        if case .completed = first {} else { Issue.record("\(first)") }
        if case .completed = held {} else { Issue.record("\(held)") }
        #expect(host.peakConcurrency == 1)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hosts.first?.held == 0)
        #expect(snapshot.hosts.first?.prefetched == 1)
    }

    /// A request sent ahead waits only if it would still finish in time.
    @Test func aHostDoesntHoldWhatWouldMissItsDeadline() async throws {
        let gate = Gate()
        let host = FakeHost(id: "local", behavior: gate.reply())
        let scheduler = await Scheduler.with([host])
        await scheduler.setTypical(5, for: "local")
        async let running = scheduler.run(Data(), onHost: "local", deadline: nil)
        #expect(await eventually { await scheduler.snapshot().hosts.first?.active == 1 })
        // 8 s, less the 1 s margin: not enough to wait up to 5 s, then run 5 s.
        let outcome = await scheduler.run(Data(), onHost: "local", deadline: Date().addingTimeInterval(8),
                                          prefetch: true)
        if case .busy = outcome {} else { Issue.record("\(outcome)") }
        await gate.release()
        _ = await running
    }

    /// A host held back on purpose, by its owner or by resource policy,
    /// answers a peer's gateway busy: it's there, with no slot to give. One
    /// that's starting or has failed is unavailable.
    @Test func aHeldBackHostAnswersPeersBusy() async throws {
        let host = FakeHost(id: "local")
        let scheduler = await Scheduler.with([host])
        func run() async -> Outcome { await scheduler.run(Data(), onHost: "local", deadline: nil) }

        await scheduler.setLimit(0, reason: MemoryRelief.reason, for: "local")
        #expect(await run() == .busy(retryAfter: 30))
        await scheduler.setLimit(nil, reason: nil, for: "local")
        for intent in [OwnerIntent.paused, .draining] {
            await scheduler.setIntent(intent, for: "local")
            #expect(await run() == .busy(retryAfter: 30), "\(intent)")
        }
        await scheduler.setIntent(.serving, for: "local")
        host.set(.paused(MemoryRelief.reason))
        await scheduler.refresh()
        #expect(await run() == .busy(retryAfter: 30))
        #expect(host.callCount == 0)

        host.set(.starting("loading the model"))
        await scheduler.refresh()
        #expect(await run() == .unavailable(retryAfter: 30, message: "loading the model"))
        host.set(.failed("self-check failed"))
        await scheduler.refresh()
        #expect(await run() == .unavailable(retryAfter: 30, message: "self-check failed"))
    }

    /// An iPad at critical memory pressure pauses before its gateways hear
    /// of it. What they send meanwhile isn't counted against it as not
    /// answering: the answer's slots say it has none, and the gateway sends
    /// nothing more until it says otherwise.
    @Test func aPeerPausedBeforeItsGatewayHeardIsntAFault() async throws {
        let peer = try await Peer()
        defer { peer.server.stop() }
        let gateway = Scheduler()
        await gateway.add(peer.remote)
        #expect(await gateway.snapshot().hosts.first?.state == .ready)
        // The peer pauses; the gateway's last status still says one slot is free.
        await peer.scheduler.setLimit(0, reason: "memory pressure is critical", for: "local")

        let outcome = await gateway.submit(Data("{}".utf8), choice: any, deadline: Date().addingTimeInterval(3),
                                           key: nil)
        if case .busy = outcome {} else { Issue.record("\(outcome)") }
        let snapshot = try #require(await gateway.snapshot().hosts.first)
        #expect(snapshot.failures.hostFaults == 0, "\(snapshot.failures)")
        #expect(snapshot.failures.busy == 1)
        #expect(snapshot.capacity == 0)
        #expect(peer.host.callCount == 0)
    }

    /// The point of it all, measured: a fast host and a slow one on other
    /// devices, behind a network's latency, and more work than slots. With
    /// one request sent ahead, the fast host's idle-with-work all but goes;
    /// the slow host is never sent anything ahead.
    @Test func prefetchCutsIdleWithWork() async throws {
        let without = try await saturate(prefetch: false)
        let with = try await saturate(prefetch: true)
        #expect(without.completed == 30 && with.completed == 30)
        #expect(without.fast.prefetched == 0)
        #expect(with.fast.prefetched > 0)
        #expect(with.slow.prefetched == 0)
        #expect(with.fast.idleWithWorkSeconds < without.fast.idleWithWorkSeconds / 3,
                "fast host idle with work: \(with.fast.idleWithWorkSeconds) s with prefetch, \(without.fast.idleWithWorkSeconds) s without")
        print("""
            idle with work, fast host: \(without.fast.idleWithWorkSeconds) s without prefetch, \
            \(with.fast.idleWithWorkSeconds) s with; slow host: \(without.slow.idleWithWorkSeconds) s, \
            \(with.slow.idleWithWorkSeconds) s; elapsed \(without.elapsed) s, \(with.elapsed) s
            """)
    }

    struct Run {
        var fast: HostSnapshot
        var slow: HostSnapshot
        var completed: Int
        var elapsed: TimeInterval
    }

    func saturate(prefetch: Bool) async throws -> Run {
        let fast = try await Peer(latency: .milliseconds(40), endpoint: String(repeating: "aa", count: 32),
                                  behavior: FakeHost.reply(after: 0.1))
        // Far apart in speed, so that however the machine running this
        // stretches them, the slow one is never within 1.5 times the fast one.
        let slow = try await Peer(latency: .milliseconds(40), endpoint: String(repeating: "bb", count: 32),
                                  behavior: FakeHost.reply(after: 3))
        defer {
            fast.server.stop()
            slow.server.stop()
        }
        var config = SchedulerConfig()
        config.prefetch = prefetch
        let gateway = Scheduler(config: config)
        for peer in [fast, slow] {
            await gateway.add(peer.remote)
            peer.remote.start()
        }
        defer {
            fast.remote.stop()
            slow.remote.stop()
        }
        await gateway.startRefreshing()
        // A few to learn typical times, as a run's first requests do.
        _ = await gateway.submit(Data("{}".utf8), choice: any, deadline: nil, key: nil)
        let start = Date()
        let deadline = Date().addingTimeInterval(60)
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<30 {
                group.addTask { await gateway.submit(Data("{}".utf8), choice: any, deadline: deadline, key: nil) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let elapsed = Date().timeIntervalSince(start)
        try await Task.sleep(for: .milliseconds(1500)) // The last free time reported.
        await gateway.stopRefreshing()
        let hosts = await gateway.snapshot().hosts
        return Run(fast: try #require(hosts.first { $0.id == fast.remote.id }),
                   slow: try #require(hosts.first { $0.id == slow.remote.id }),
                   completed: outcomes.filter { if case .completed = $0 { true } else { false } }.count,
                   elapsed: elapsed)
    }
}
