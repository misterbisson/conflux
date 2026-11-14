import Foundation
import Testing
@testable import ConfluxCore

/// The USE method's counters: utilization, saturation and errors, for the
/// mesh and each host.
@Suite struct MonitoringTests {
    let any = ModelChoice(model: nil, preference: nil)
    /// On a minute.
    let minute = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Slot-seconds by the minute

    @Test func slotSecondsAreSharedOutOverTheMinutesTheySpan() {
        var log = ActivityLog()
        // Half a minute either side of one: half in each.
        log.slots(busy: 60, offered: 120, from: minute.addingTimeInterval(-30), to: minute.addingTimeInterval(30))
        #expect(log.minutes.count == 2)
        #expect(log.minutes.map(\.busySlotSeconds) == [30, 30])
        #expect(log.minutes.map(\.slotSeconds) == [60, 60])
        #expect(ActivityTotals(log.minutes).utilization == 0.5)
        // Nothing offered adds no minute.
        log.slots(busy: 0, offered: 0, from: minute, to: minute.addingTimeInterval(90))
        #expect(log.minutes.count == 2)
    }

    @Test func aSpanLongerThanADayKeepsItsLastDay() {
        var log = ActivityLog()
        let end = minute.addingTimeInterval(3 * 86400)
        log.slots(busy: 3 * 86400, offered: 3 * 86400, from: minute, to: end)
        #expect(log.minutes.count == ActivityLog.minutesKept)
        #expect(abs(ActivityTotals(log.minutes).slotSeconds - 86400) < 0.001)
    }

    @Test func utilizationNeedsSlotsOffered() {
        #expect(ActivityTotals([ActivityMinute(minute: 1)]).utilization == nil)
        #expect(ActivityTotals([ActivityMinute(minute: 1, busySlotSeconds: 30, slotSeconds: 120)]).utilization == 0.25)
        // Rounding between counts can't make it more than all.
        #expect(ActivityTotals([ActivityMinute(minute: 1, busySlotSeconds: 61, slotSeconds: 60)]).utilization == 1)
    }

    @Test func percentilesByNearestRank() {
        #expect(Percentiles([]) == nil)
        #expect(Percentiles([4]) == Percentiles(p50: 4, p95: 4, count: 1))
        #expect(Percentiles((1...20).map(Double.init).shuffled()) == Percentiles(p50: 10, p95: 19, count: 20))
        #expect(Percentiles([0, 0, 0, 9]) == Percentiles(p50: 0, p95: 9, count: 4))
    }

    // MARK: The scheduler

    @Test func utilizationIsBusySlotTimeOverOfferedSlotTime() async throws {
        let gate = Gate()
        let host = FakeHost(id: "h", slots: 2, behavior: gate.reply())
        let idle = FakeHost(id: "idle", model: "model-b")
        let scheduler = await Scheduler.with([host, idle])
        let running = Task { await scheduler.submit(Data(), choice: ModelChoice(model: "model-a", preference: nil),
                                                    deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().hosts.first?.active == 1 })
        // One slot of two busy from here on: utilization climbs towards half,
        // however long the moment before took on a slow machine, and never
        // passes it.
        func current(_ id: String) async -> HostSnapshot? { await scheduler.snapshot().hosts.first { $0.id == id } }
        #expect(await eventually { (await current("h")?.utilization ?? 0) > 0.4 })
        let snapshot = await scheduler.snapshot()
        let hosts = Dictionary(uniqueKeysWithValues: snapshot.hosts.map { ($0.id, $0) })
        let busy = try #require(hosts["h"]?.utilization)
        #expect(busy > 0.4 && busy <= 0.5 + 1e-9, "utilization \(busy)")
        #expect(hosts["idle"]?.utilization == 0)
        // The mesh's: one slot busy of three, at most.
        let mesh = try #require(snapshot.utilization)
        #expect(mesh > 0 && mesh <= 1.0 / 3 + 1e-9, "mesh utilization \(mesh)")
        // The counts since it was added say the same.
        let counted = try #require(hosts["h"])
        #expect(counted.busySlotSeconds > 0 && counted.busySlotSeconds <= counted.slotSeconds / 2 + 1e-9)
        // The activity has it by the minute.
        let minutes = await scheduler.activity(since: Date().addingTimeInterval(-120))["h"] ?? []
        #expect(ActivityTotals(minutes).busySlotSeconds > 0)
        await gate.release()
        _ = await running.value
    }

    @Test func aHostThatOffersNoSlotHasNoUtilization() async {
        let host = FakeHost(id: "h", availability: .starting("loading the model"))
        let scheduler = await Scheduler.with([host])
        try? await Task.sleep(for: .milliseconds(50))
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hosts.first?.utilization == nil)
        #expect(snapshot.utilization == nil)
    }

    @Test func aPeersHostIsMeasuredByItsOwnCount() async throws {
        // The host's own count, whichever gateways sent the work: 3 of 4
        // slot-seconds busy between two reports.
        let host = FakeHost(id: "peer")
        host.report(free: 1, busySlotSeconds: 10, slotSeconds: 20, at: Date().addingTimeInterval(-60))
        let scheduler = await Scheduler.with([host])
        host.report(free: 1, busySlotSeconds: 13, slotSeconds: 24, at: Date())
        await scheduler.refresh()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await scheduler.snapshot()
        #expect(abs(try #require(snapshot.hosts.first?.utilization) - 0.75) < 1e-9)
        #expect(abs(try #require(snapshot.utilization) - 0.75) < 1e-9)
        // A count that went down is a host that restarted: nothing added.
        host.report(free: 1, busySlotSeconds: 1, slotSeconds: 2, at: Date().addingTimeInterval(1))
        await scheduler.refresh()
        #expect(abs(try #require(await scheduler.snapshot().hosts.first?.utilization) - 0.75) < 1e-9)
    }

    @Test func waitsAtTheGatewayHaveAMedianAndATail() async throws {
        let gate = Gate()
        let host = FakeHost(id: "h", behavior: gate.reply())
        let scheduler = await Scheduler.with([host])
        let first = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().hosts.first?.active == 1 })
        let second = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().queued == 1 })
        try await Task.sleep(for: .milliseconds(300))
        await gate.release()
        _ = await first.value
        _ = await second.value
        let wait = try #require(await scheduler.snapshot().waitSeconds)
        #expect(wait.count == 2)
        // The first had the slot at once; the second waited for it.
        #expect(wait.p50 < 0.1, "median wait \(wait.p50)")
        #expect(wait.p95 >= 0.3, "p95 wait \(wait.p95)")
    }

    @Test func eachHostHasATailOfRequestTime() async throws {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0.05))
        let scheduler = await Scheduler.with([host])
        for _ in 0..<3 { _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        let request = try #require(await scheduler.snapshot().hosts.first?.requestSeconds)
        #expect(request.count == 3)
        #expect(request.p50 >= 0.05)
        #expect(request.p95 >= request.p50)
    }

    @Test func aHostThatComesBackKeepsItsCounts() async throws {
        let behavior: @Sendable (Int) async throws -> HostReply = { call in
            if call == 1 { throw HostError.failed(status: 500, message: "boom") }
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        let scheduler = await Scheduler.with([FakeHost(id: "peer-h", behavior: behavior)])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        let before = try #require(await scheduler.snapshot().hosts.first)
        #expect(before.completed == 1)
        #expect(before.failures == FailureCounts(failed: 1))
        #expect(before.rejoined == 0)

        // Leaves, as when its peer disconnects, and comes back.
        await scheduler.remove(hostID: "peer-h")
        await scheduler.add(FakeHost(id: "peer-h"))
        var after = try #require(await scheduler.snapshot().hosts.first)
        #expect(after.completed == 1)
        #expect(after.failures == FailureCounts(failed: 1))
        #expect(after.perHour == 6)
        #expect(after.requestSeconds?.count == 1)
        #expect(after.slotSeconds >= before.slotSeconds)
        #expect(after.rejoined == 1)

        // Replaced without leaving: the same counts, and it didn't rejoin.
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        await scheduler.add(FakeHost(id: "peer-h"))
        after = try #require(await scheduler.snapshot().hosts.first)
        #expect(after.completed == 2)
        #expect(after.rejoined == 1)
        // The gateway's own count agrees.
        #expect(await scheduler.snapshot().completed == 2)
    }

    // MARK: What's reported

    @Test func healthAddsTheUseCounters() throws {
        let host = HostSnapshot(id: "local", state: .ready, utilization: 0.4567,
                                requestSeconds: Percentiles(p50: 1.23456, p95: 4.5, count: 12), rejoined: 2)
        let snapshot = SchedulerSnapshot(
            hosts: [host], queued: 3, completed: 0, failures: FailureCounts(), rejected: 0, busy: 0, unavailable: 0,
            hedged: 0, hedgeWins: 0, perHour: 0, idleWithWorkSeconds: 0, utilization: 0.25,
            waitSeconds: Percentiles(p50: 0, p95: 2.5, count: 40))
        let body = try JSONSerialization.data(withJSONObject: Gateway.health(snapshot))
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let mesh = try #require(object["mesh"] as? [String: Any])
        #expect(mesh["utilization"] as? Double == 0.25)
        #expect(mesh["queued"] as? Int == 3)
        let wait = try #require(mesh["wait_seconds"] as? [String: Any])
        #expect(wait["p95"] as? Double == 2.5)
        #expect(wait["count"] as? Int == 40)
        let entry = try #require((object["hosts"] as? [[String: Any]])?.first)
        #expect(entry["utilization"] as? Double == 0.457)
        #expect(entry["rejoined"] as? Int == 2)
        let request = try #require(entry["request_seconds"] as? [String: Any])
        #expect(request["p50"] as? Double == 1.235)
        #expect(request["p95"] as? Double == 4.5)
        #expect(request["count"] as? Int == 12)
    }

    @Test func healthLeavesOutWhatIsntMeasuredYet() throws {
        let snapshot = SchedulerSnapshot(
            hosts: [HostSnapshot(id: "local", state: .ready)], queued: 0, completed: 0, failures: FailureCounts(),
            rejected: 0, busy: 0, unavailable: 0, hedged: 0, hedgeWins: 0, perHour: 0, idleWithWorkSeconds: 0)
        let health = Gateway.health(snapshot)
        let mesh = try #require(health["mesh"] as? [String: Any])
        #expect(mesh["utilization"] == nil)
        #expect(mesh["wait_seconds"] == nil)
        let entry = try #require((health["hosts"] as? [[String: Any]])?.first)
        #expect(entry["utilization"] == nil)
        #expect(entry["request_seconds"] == nil)
        #expect(entry["rejoined"] as? Int == 0)
    }

    @Test func aHostReportsItsSlotSecondsToPeers() throws {
        let snapshot = HostSnapshot(id: "local", state: .ready, slots: 2, busySlotSeconds: 30, slotSeconds: 120)
        let status = HostStatus(snapshot)
        let json = try #require(String(data: try HostService.encoder.encode(status), encoding: .utf8))
        #expect(json.contains("\"busy_slot_seconds\":30"))
        #expect(json.contains("\"slot_seconds\":120"))
        // A status from before they were counted still reads.
        var old = try #require(try JSONSerialization.jsonObject(with: try HostService.encoder.encode(status))
            as? [String: Any])
        old["busy_slot_seconds"] = nil
        old["slot_seconds"] = nil
        let read = try HostService.decoder.decode(HostStatus.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(read.busySlotSeconds == nil)
        #expect(read.slotSeconds == nil)
    }
}
