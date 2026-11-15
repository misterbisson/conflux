import Foundation
import Testing
@testable import ConfluxCore

@Suite struct EventLogTests {
    let any = ModelChoice(model: nil, preference: nil)

    /// A log in a folder of its own, which doesn't exist yet.
    func temporaryLog(limit: Int = 4 << 20) -> EventLog {
        let folder = FileManager.default.temporaryDirectory.appending(path: "conflux-events-\(UUID().uuidString)")
        return EventLog(url: folder.appending(path: "mesh.log"), limit: limit)
    }

    /// Each line's subject and message, without the time.
    func events(_ log: EventLog) -> [(subject: String, message: String)] {
        log.read().split(separator: "\n").map { line in
            let fields = line.components(separatedBy: "  ")
            return (fields[1], fields.dropFirst(2).joined(separator: "  "))
        }
    }

    func messages(_ log: EventLog, about subject: String) -> [String] {
        events(log).filter { $0.subject == subject }.map(\.message)
    }

    /// Events written at once, as tests want them: no settling, no gap,
    /// summaries only when a test asks for them.
    func config(settle: TimeInterval = 0, gap: TimeInterval = 0, summary: TimeInterval = 3600) -> SchedulerConfig {
        var config = SchedulerConfig()
        config.eventSettle = settle
        config.eventGap = gap
        config.eventSummary = summary
        return config
    }

    @Test func linesSayWhenWhatAndWhatHappened() throws {
        let date = Date(timeIntervalSince1970: 1_794_730_098.25)
        let line = EventLog.line("peer-0123456789", "starting: can't reach\nthe peer", at: date)
        #expect(line.hasSuffix("  peer-0123456789  starting: can't reach the peer\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        let time = try #require(line.components(separatedBy: "  ").first)
        let parsed = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
    }

    @Test func durationsAreShort() {
        #expect(EventLog.duration(42) == "42s")
        #expect(EventLog.duration(190) == "3m 10s")
        #expect(EventLog.duration(6 * 3600 + 25 * 60 + 9) == "6h 25m")
        #expect(EventLog.duration(2 * 86400 + 3 * 3600) == "2d 3h")
        #expect(EventLog.duration(300) == "5m")
        #expect(EventLog.duration(7200) == "2h")
    }

    @Test func movesAsideWhenFullAndReadsBothInOrder() throws {
        let log = temporaryLog(limit: 300)
        for index in 0..<10 { log.record("node", "event \(index)") }
        log.flush()
        let current = try Data(contentsOf: log.url).count
        let previous = try Data(contentsOf: log.previousURL).count
        #expect(current <= 300 && previous <= 300)
        let read = events(log).map(\.message)
        #expect(read.last == "event 9")
        #expect(read == read.sorted { Int($0.dropFirst(6))! < Int($1.dropFirst(6))! })
    }

    @Test func goesOnFromWhatAnEarlierLaunchWrote() {
        let log = temporaryLog()
        log.record("node", "started")
        log.flush()
        let again = EventLog(url: log.url)
        again.record("node", "started again")
        #expect(events(again).map(\.message) == ["started", "started again"])
    }

    @Test func writesAHostsStateAsItChangesButNotEachRequest() async {
        let log = temporaryLog()
        let host = FakeHost(id: "h", slots: 1)
        let scheduler = Scheduler(config: config(), events: log)
        await scheduler.add(host)
        // Busy and ready again, with each request: still serving.
        for _ in 0..<3 { _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        host.set(.starting("loading the model"))
        await scheduler.refresh()
        host.set(.available)
        await scheduler.refresh()
        log.flush()
        let lines = messages(log, about: "h")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("serving model-a, 1 slot, on "))
        #expect(lines[1].hasPrefix("starting: loading the model (serving for "))
        // The device is described once.
        #expect(lines[2].hasPrefix("serving model-a, 1 slot (starting for "))
    }

    @Test func aBlipShorterThanTheSettleTimeIsNoLine() async {
        let log = temporaryLog()
        let host = FakeHost(id: "h")
        let scheduler = Scheduler(config: config(settle: 30), events: log)
        await scheduler.add(host)
        host.set(.starting("the peer isn't answering"))
        await scheduler.refresh()
        host.set(.available)
        await scheduler.refresh()
        log.flush()
        #expect(messages(log, about: "h").isEmpty)
    }

    @Test func aHostThatKeepsChangingIsWrittenAtMostOnceAGap() async throws {
        let log = temporaryLog()
        let host = FakeHost(id: "h")
        let scheduler = Scheduler(config: config(gap: 1.5), events: log)
        await scheduler.add(host)
        let before = Date()
        host.set(.starting("first"))
        await scheduler.refresh()
        host.set(.starting("second"))
        await scheduler.refresh()
        try await Task.sleep(for: .milliseconds(1600))
        await scheduler.refresh()
        log.flush()
        let lines = messages(log, about: "h")
        #expect(lines.count == 2)
        #expect(lines.last == "starting: second (1 shorter change since serving)")
        // Written late, at the time it began.
        let time = try #require(log.read().split(separator: "\n").last?.components(separatedBy: "  ").first)
        let began = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)
        #expect(began.timeIntervalSince(before) < 1.5)
    }

    @Test func saysWhyAHostHasFewerSlots() async {
        let log = temporaryLog()
        let host = FakeHost(id: "h", slots: 2)
        let scheduler = Scheduler(config: config(), events: log)
        await scheduler.add(host)
        await scheduler.setLimit(1, reason: "the Mac is hot", for: "h")
        log.flush()
        #expect(messages(log, about: "h").last?.hasPrefix("serving model-a, 1 slot of 2: the Mac is hot (") == true)
    }

    @Test func sumsUpWhatEachHostDidAndWhyItFailed() async throws {
        let log = temporaryLog()
        // Slow enough that a summary falls among the requests.
        let good = FakeHost(id: "good", behavior: FakeHost.reply(after: 0.15))
        let bad = FakeHost(id: "bad") { _ in throw HostError.unavailable("this device isn't taking work") }
        let scheduler = Scheduler(config: config(summary: 0.3), events: log)
        await scheduler.add(bad)
        await scheduler.add(good)
        for _ in 0..<4 { _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        try await Task.sleep(for: .milliseconds(400))
        await scheduler.refresh()
        log.flush()
        // A slow machine can sum up partway through the requests, so the
        // counts may be split across summaries: they add up.
        #expect(total("completed", in: summaries(log, about: "good")) == 4)
        let refusals = summaries(log, about: "bad")
        #expect(total("unavailable", in: refusals) >= 1)
        #expect(refusals.contains { $0.hasSuffix("; last failure: this device isn't taking work") })
        #expect(total("completed", in: summaries(log, about: "gateway")) == 4)
    }

    func summaries(_ log: EventLog, about subject: String) -> [String] {
        messages(log, about: subject).filter { $0.hasPrefix("last ") }
    }

    /// The count of `what` in each summary, such as `3` in "3 completed",
    /// added up.
    func total(_ what: String, in summaries: [String]) -> Int {
        summaries.reduce(0) { sum, line in
            let counts = line.drop { $0 != ":" }.dropFirst().split(separator: ";").first ?? ""
            return sum + counts.split(separator: ",").reduce(0) { sum, part in
                let words = part.split(separator: " ", maxSplits: 1)
                guard words.count == 2, words[1] == what, let n = Int(words[0]) else { return sum }
                return sum + n
            }
        }
    }

    @Test func aQuietHostIsNotSummedUp() async throws {
        let log = temporaryLog()
        let scheduler = Scheduler(config: config(summary: 0.2), events: log)
        await scheduler.add(FakeHost(id: "h"))
        try await Task.sleep(for: .milliseconds(300))
        await scheduler.refresh()
        log.flush()
        #expect(!messages(log, about: "h").contains { $0.hasPrefix("last ") })
        #expect(messages(log, about: "gateway").isEmpty)
    }

    @Test func saysWhenAHostIsRemoved() async {
        let log = temporaryLog()
        let scheduler = Scheduler(config: config(), events: log)
        await scheduler.add(FakeHost(id: "h"))
        await scheduler.remove(hostID: "h")
        log.flush()
        #expect(messages(log, about: "h").last?.hasPrefix("removed (serving for ") == true)
    }

    @Test func aNodeSaysWhenItStartsAndStopsOnce() async throws {
        let log = temporaryLog()
        let node = ConfluxNode(scheduler: Scheduler(config: config(), events: log))
        // Starting stops first: nothing had started, so nothing stopped.
        try await node.start(NodeSettings(port: 0, requireToken: false, iCloudKeychain: false))
        await node.stop()
        await node.stop()
        log.flush()
        let lines = messages(log, about: "node")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("started: conflux ") == true)
        #expect(lines.first?.contains("gateway on 127.0.0.1:") == true)
        #expect(lines.last == "stopped")
    }

    @Test func withoutALogNothingIsWritten() async {
        let scheduler = await Scheduler.with([FakeHost(id: "h")])
        _ = await scheduler.submit(Data(), choice: any, deadline: nil, key: nil)
        #expect(scheduler.events == nil)
    }
}
