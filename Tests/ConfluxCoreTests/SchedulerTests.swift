import Foundation
import Testing
@testable import ConfluxCore

@Suite struct SchedulerTests {
    let any = ModelChoice(model: nil, preference: nil)

    @Test func completesAndNamesTheModel() async {
        let host = FakeHost(id: "h")
        let scheduler = await Scheduler.with([host])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        guard case .completed(let reply, let model) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reply.status == 200)
        #expect(model.id == "model-a")
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.completed == 1)
        #expect(snapshot.hosts.first?.typicalSeconds != nil)
    }

    @Test func neverExceedsSlots() async {
        let host = FakeHost(id: "h", slots: 2, behavior: FakeHost.reply(after: 0.1))
        let scheduler = await Scheduler.with([host])
        let deadline = Date().addingTimeInterval(10)
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<6 { group.addTask { await scheduler.submit(Data(), choice: any, deadline: deadline, key: nil) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { if case .completed = $0 { true } else { false } })
        #expect(host.peakConcurrency == 2)
        #expect(host.callCount == 6)
        // Near zero: a freed slot goes straight to waiting work. Generous
        // enough for a loaded runner.
        #expect(await scheduler.snapshot().idleWithWorkSeconds < 0.3)
    }

    @Test func countsPerHostAndByKind() async {
        let good = FakeHost(id: "good", behavior: FakeHost.reply(after: 0.05))
        let broken = FakeHost(id: "broken") { call in
            if call == 1 { throw HostError.unavailable("connection refused") }
            if call == 2 { throw HostError.busy("taken") }
            throw HostError.failed(status: 500, message: "boom")
        }
        let scheduler = await Scheduler.with([broken, good])
        for _ in 0..<3 {
            await scheduler.refresh() // Back from "not answering".
            let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(5), key: nil)
            if case .completed = outcome {} else { Issue.record("\(outcome)") }
        }
        let snapshot = await scheduler.snapshot()
        let hosts = Dictionary(uniqueKeysWithValues: snapshot.hosts.map { ($0.id, $0) })
        #expect(hosts["broken"]?.failures == FailureCounts(unavailable: 1, failed: 1, busy: 1))
        #expect(hosts["broken"]?.failed == 2)
        #expect(hosts["broken"]?.completed == 0)
        #expect(hosts["good"]?.completed == 3)
        #expect(hosts["good"]?.perHour == 18)
        #expect(hosts["good"]?.failures.total == 0)
        #expect(snapshot.failures == FailureCounts(unavailable: 1, failed: 1, busy: 1))
        #expect(snapshot.completed == 3)
        #expect(snapshot.perHour == 18)
    }

    @Test func runningOutOfTimeIsntTheHostsFault() async {
        let host = FakeHost(id: "h") { _ in
            try await Task.sleep(for: .seconds(1.6))
            throw HostError.unavailable("timed out")
        }
        let scheduler = await Scheduler.with([host])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(2), key: nil)
        if case .unavailable = outcome {} else { Issue.record("\(outcome)") }
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.failures == FailureCounts(deadline: 1))
        #expect(snapshot.hosts.first?.failures == FailureCounts(deadline: 1))
        #expect(snapshot.failed == 0)
    }

    /// A host on another device reports its own free time. The part spent
    /// while work for it waited here is idle with work.
    @Test func countsAReportedFreeTimeWhileWorkWaits() async throws {
        let host = FakeHost(id: "peer", behavior: FakeHost.reply(after: 3))
        host.report(freeSeconds: 10, at: Date())
        let scheduler = await Scheduler.with([host])
        let running = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        // Busy CI runners start tasks late: wait for each step to happen
        // rather than for a fixed time.
        while await scheduler.snapshot().hosts.first?.active == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        while await scheduler.snapshot().queued == 0 { try await Task.sleep(for: .milliseconds(10)) }
        // A report taken while work waits starts the span. Nothing was free
        // before it.
        host.report(freeSeconds: 10, at: Date())
        await scheduler.refresh()
        try await Task.sleep(for: .milliseconds(500))
        // Since then, the host says it had a free slot for a quarter of a
        // second, all of it while work waited here.
        host.report(freeSeconds: 10.25, at: Date())
        await scheduler.refresh()
        let idle = try #require(await scheduler.snapshot().hosts.first?.idleWithWorkSeconds)
        #expect(idle > 0.2 && idle <= 0.25, "idle with work \(idle) s")
        _ = await (running.value, waiting.value)

        // Free time with nothing waiting isn't idle with work.
        host.report(freeSeconds: 12, at: Date())
        await scheduler.refresh()
        let before = try #require(await scheduler.snapshot().hosts.first?.idleWithWorkSeconds)
        try await Task.sleep(for: .milliseconds(300))
        host.report(freeSeconds: 12.3, at: Date())
        await scheduler.refresh()
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hosts.first?.idleWithWorkSeconds == before)
        #expect(snapshot.idleWithWorkSeconds == before)
    }

    @Test func answersBusyBeforeTheDeadline() async {
        // The scheduler answers `margin` before the deadline. A wide margin
        // leaves room for a slow runner to wake late and still be in time.
        var config = SchedulerConfig()
        config.margin = 2
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 5))
        let scheduler = await Scheduler.with([host], config: config)
        let first = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        // Busy CI runners can start the first late: wait until it holds the slot.
        while await scheduler.snapshot().hosts.first?.active == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let start = Date()
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(3), key: nil)
        let elapsed = Date().timeIntervalSince(start)
        guard case .busy(let retryAfter) = outcome else { Issue.record("\(outcome)"); return }
        #expect(retryAfter >= 1)
        #expect(elapsed < 3, "answered in \(elapsed) s, past the deadline")
        _ = await first.value
    }

    @Test func requestsWithoutADeadlineWaitTheDefault() async {
        var config = SchedulerConfig()
        config.defaultQueueWait = 0.3
        // The slot frees long after the default wait, so the two can't be
        // mistaken for each other on a slow runner.
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 4))
        let scheduler = await Scheduler.with([host], config: config)
        let first = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        // Busy CI runners can start the first late: wait until it holds the slot.
        while await scheduler.snapshot().hosts.first?.active == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let start = Date()
        let outcome = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        guard case .busy(let retryAfter) = outcome else { Issue.record("\(outcome)"); return }
        #expect((1...4).contains(retryAfter))
        // The default wait, not the slot's 4 s.
        #expect(Date().timeIntervalSince(start) < 3)
        _ = await first.value
    }

    @Test func waitingRequestsGetTheNextFreeSlot() async {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0.2))
        let scheduler = await Scheduler.with([host])
        let deadline = Date().addingTimeInterval(5)
        async let a = scheduler.submit(Data(), choice: any, deadline: deadline, key: nil)
        async let b = scheduler.submit(Data(), choice: any, deadline: deadline, key: nil)
        let outcomes = await [a, b]
        #expect(outcomes.allSatisfy { if case .completed = $0 { true } else { false } })
        #expect(host.peakConcurrency == 1)
    }

    @Test func doesNotSendWhatCannotFinishInTime() async {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0.6))
        let scheduler = await Scheduler.with([host])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) // learns ~0.6 s
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(1.2), key: nil)
        if case .busy = outcome {} else { Issue.record("\(outcome)") }
        #expect(host.callCount == 1)
    }

    @Test func failsOverToAnotherHost() async {
        let broken = FakeHost(id: "broken") { _ in throw HostError.unavailable("connection refused") }
        let good = FakeHost(id: "good")
        let scheduler = await Scheduler.with([broken, good])
        await scheduler.setIntent(.paused, for: "good")
        await scheduler.setIntent(.serving, for: "good")
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(5), key: nil)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(await scheduler.snapshot().failed <= 1)
    }

    @Test func aFailedOnlyHostMeans503() async {
        let broken = FakeHost(id: "broken") { _ in throw HostError.failed(status: 500, message: "boom") }
        let scheduler = await Scheduler.with([broken])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        guard case .unavailable(let retryAfter, let message) = outcome else { Issue.record("\(outcome)"); return }
        #expect(retryAfter == 5)
        #expect(message.contains("500"))
    }

    @Test func runtimeRefusalsPassThrough() async {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0, status: 400, body: Data("{}".utf8)))
        let scheduler = await Scheduler.with([host])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        guard case .rejected(let reply, let model) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reply == HostReply(status: 400, body: Data("{}".utf8)))
        #expect(model.id == "model-a")
    }

    @Test func sameKeyRunsOnce() async {
        let host = FakeHost(id: "h", slots: 4, behavior: FakeHost.reply(after: 0.2))
        let scheduler = await Scheduler.with([host])
        async let a = scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        async let b = scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        let (first, second) = await (a, b)
        #expect(first == second)
        let third = await scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        #expect(third == first)
        #expect(host.callCount == 1)
    }

    @Test func failuresAreNotRemembered() async {
        let host = FakeHost(id: "h") { call in
            if call == 1 { throw HostError.failed(status: 500, message: "once") }
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        let scheduler = await Scheduler.with([host])
        let first = await scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        if case .unavailable = first {} else { Issue.record("\(first)") }
        let second = await scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        if case .completed = second {} else { Issue.record("\(second)") }
    }

    @Test func unknownModels() async {
        let host = FakeHost(id: "h")
        let scheduler = await Scheduler.with([host])
        let outcome = await scheduler.submit(Data(), choice: ModelChoice(model: "other", preference: nil),
                                             deadline: nil, key: nil)
        guard case .unknownModel(let message) = outcome else { Issue.record("\(outcome)"); return }
        #expect(message.contains("other"))
    }

    @Test func aKnownModelWithNoHostUpIs503() async {
        let host = FakeHost(id: "h")
        let scheduler = await Scheduler.with([host])
        await scheduler.remove(hostID: "h")
        let outcome = await scheduler.submit(Data(), choice: ModelChoice(model: "model-a", preference: nil),
                                             deadline: nil, key: nil)
        if case .unavailable(30, _) = outcome {} else { Issue.record("\(outcome)") }
    }

    @Test func startingHostsAskForAShortRetry() async {
        let host = FakeHost(id: "h", availability: .starting("loading the model"))
        let scheduler = await Scheduler.with([host])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        #expect(outcome == .unavailable(retryAfter: 5, message: "loading the model"))
        #expect(await scheduler.snapshot().hosts.first?.state == .starting("loading the model"))
    }

    @Test func pausedAndLimitedHostsTakeNothing() async {
        let host = FakeHost(id: "h")
        let scheduler = await Scheduler.with([host])
        await scheduler.setIntent(.paused, for: "h")
        #expect(await scheduler.snapshot().hosts.first?.state == .paused("paused by its owner"))
        let paused = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        if case .unavailable(30, _) = paused {} else { Issue.record("\(paused)") }

        await scheduler.setIntent(.serving, for: "h")
        await scheduler.setLimit(0, reason: "too hot", for: "h")
        #expect(await scheduler.snapshot().hosts.first?.state == .paused("too hot"))
        await scheduler.setLimit(nil, reason: nil, for: "h")
        #expect(await scheduler.snapshot().hosts.first?.state == .ready)
        #expect(host.callCount == 0)
    }

    @Test func drainingFinishesWhatsRunning() async {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0.3))
        let scheduler = await Scheduler.with([host])
        let running = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        while await scheduler.snapshot().hosts.first?.active == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        await scheduler.setIntent(.draining, for: "h")
        #expect(await scheduler.snapshot().hosts.first?.state == .draining)
        if case .completed = await running.value {} else { Issue.record("the running request should finish") }
        #expect(await scheduler.snapshot().hosts.first?.state == .paused("drained"))
    }

    @Test func preferenceListTakesTheFirstFreeModel() async {
        let a = FakeHost(id: "a", model: "model-a", behavior: FakeHost.reply(after: 0.5))
        let b = FakeHost(id: "b", model: "model-b")
        let scheduler = await Scheduler.with([a, b])
        let choice = ModelChoice(model: nil, preference: "model-a, model-b")
        let first = await scheduler.submit(Data(), choice: ModelChoice(model: "model-a", preference: nil),
                                           deadline: nil, key: nil)
        if case .completed(_, let model) = first { #expect(model.id == "model-a") }
        let busyA = Task { await scheduler.submit(Data(), choice: ModelChoice(model: "model-a", preference: nil),
                                                  deadline: nil, key: nil) }
        while await scheduler.snapshot().hosts.first(where: { $0.id == "a" })?.active == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let outcome = await scheduler.submit(Data(), choice: choice, deadline: nil, key: nil)
        if case .completed(_, let model) = outcome { #expect(model.id == "model-b") } else { Issue.record("\(outcome)") }
        _ = await busyA.value
    }

    @Test func capabilityAliases() async {
        let text = FakeHost(id: "t", model: "text-model", capabilities: [.text])
        let scheduler = await Scheduler.with([text])
        let vision = await scheduler.submit(Data(), choice: ModelChoice(model: "any-vision", preference: nil),
                                            deadline: nil, key: nil)
        if case .unknownModel = vision {} else { Issue.record("\(vision)") }
        let anything = await scheduler.submit(Data(), choice: ModelChoice(model: "any", preference: nil),
                                              deadline: nil, key: nil)
        if case .completed = anything {} else { Issue.record("\(anything)") }
    }
}

@Suite struct ModelChoiceTests {
    let model = ModelInfo(id: "m", capabilities: [.text, .vision], fingerprint: "f")

    @Test func parsing() {
        #expect(ModelChoice(model: nil, preference: nil).options == [.any])
        #expect(ModelChoice(model: "", preference: nil).options == [.any])
        #expect(ModelChoice(model: "m", preference: nil).options == [.exact("m")])
        #expect(ModelChoice(model: "m", preference: " a, any-vision ,b ").options
            == [.exact("a"), .capability(.vision), .exact("b")])
    }

    @Test func ranking() {
        #expect(ModelChoice(model: nil, preference: "x, m").rank(model) == 1)
        #expect(ModelChoice(model: nil, preference: "any-vision").rank(model) == 0)
        #expect(ModelChoice(model: "x", preference: nil).rank(model) == nil)
    }
}

@Suite struct ResourcePolicyTests {
    @Test func limits() {
        #expect(ResourcePolicy.limit(slots: 4, reading: ResourceReading()) == (4, nil))
        #expect(ResourcePolicy.limit(slots: 4, reading: ResourceReading(thermal: .critical)).slots == 0)
        #expect(ResourcePolicy.limit(slots: 4, reading: ResourceReading(memory: .critical)).slots == 0)
        #expect(ResourcePolicy.limit(slots: 4, reading: ResourceReading(thermal: .serious)).slots == 2)
        #expect(ResourcePolicy.limit(slots: 1, reading: ResourceReading(memory: .warning)).slots == 1)
        let both = ResourcePolicy.limit(slots: 8, reading: ResourceReading(thermal: .serious, lowPowerMode: true))
        #expect(both.slots == 4)
        #expect(both.reason?.contains("Low Power Mode") == true)
    }
}
