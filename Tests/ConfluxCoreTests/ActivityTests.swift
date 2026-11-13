import Foundation
import Testing
@testable import ConfluxCore

@Suite struct ActivityTests {
    let any = ModelChoice(model: nil, preference: nil)
    let noon = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsUsageAndTimings() {
        let body = Data(#"""
            {"usage":{"prompt_tokens":812,"completion_tokens":40},"timings":{"predicted_ms":1250.5}}
            """#.utf8)
        #expect(Usage(body) == Usage(prompt: 812, completion: 40, writingSeconds: 1.2505))
        let noTimings = Data(#"{"usage":{"prompt_tokens":3,"completion_tokens":2}}"#.utf8)
        #expect(Usage(noTimings) == Usage(prompt: 3, completion: 2, writingSeconds: 0))
        #expect(Usage(Data("not json".utf8)) == nil)
        #expect(Usage(Data(#"{"choices":[]}"#.utf8)) == nil)
    }

    @Test func addsUpEachMinute() {
        var log = ActivityLog()
        let usage = Usage(prompt: 100, completion: 10, writingSeconds: 0.5)
        log.completed(usage, at: noon)
        log.completed(usage, at: noon.addingTimeInterval(20))
        log.failed(at: noon.addingTimeInterval(30))
        log.completed(nil, at: noon.addingTimeInterval(90))
        #expect(log.minutes.count == 2)
        let first = log.minutes[0]
        #expect(first.completed == 2 && first.failed == 1)
        #expect(first.promptTokens == 200 && first.completionTokens == 20 && first.writingSeconds == 1)
        #expect(log.minutes[1].completed == 1 && log.minutes[1].promptTokens == 0)
        #expect(ActivityTotals(log.minutes).tokensPerSecond == 20)
        #expect(ActivityTotals([]).tokensPerSecond == nil)
    }

    @Test func keepsADayInOrder() {
        var log = ActivityLog()
        log.completed(nil, at: noon)
        // A clock set back: the minute goes where it sorts.
        log.completed(nil, at: noon.addingTimeInterval(-600))
        log.completed(nil, at: noon.addingTimeInterval(-600))
        #expect(log.minutes.map(\.completed) == [2, 1])
        #expect(log.minutes.map(\.minute) == log.minutes.map(\.minute).sorted())
        // A day later, both are gone.
        log.completed(nil, at: noon.addingTimeInterval(24 * 3600))
        #expect(log.minutes.count == 1)
        #expect(log.since(noon).count == 1)
    }

    @Test func theSchedulerRecordsCompletionsAndHostFaults() async {
        let body = Data(#"{"usage":{"prompt_tokens":50,"completion_tokens":5},"timings":{"predicted_ms":100}}"#.utf8)
        let good = FakeHost(id: "good", behavior: FakeHost.reply(after: 0.05, body: body))
        let broken = FakeHost(id: "broken") { call in
            if call == 1 { throw HostError.busy("taken") }
            throw HostError.failed(status: 500, message: "boom")
        }
        let scheduler = await Scheduler.with([broken, good])
        for _ in 0..<2 {
            await scheduler.refresh()
            _ = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(5), key: nil)
        }
        let activity = await scheduler.activity(since: Date().addingTimeInterval(-60))
        let totals = ActivityTotals(activity["good"] ?? [])
        #expect(totals.completed == 2)
        #expect(totals.promptTokens == 100 && totals.completionTokens == 10)
        #expect(totals.tokensPerSecond == 50)
        // Busy isn't the host's fault; the server error is.
        #expect(ActivityTotals(activity["broken"] ?? []).failed == 1)
        // Kept after the host leaves.
        await scheduler.remove(hostID: "good")
        #expect(await scheduler.activity(since: Date().addingTimeInterval(-60))["good"] != nil)
    }
}
