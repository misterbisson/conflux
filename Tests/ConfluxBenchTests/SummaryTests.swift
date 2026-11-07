import Foundation
import Testing
@testable import ConfluxBench

@Suite struct SummaryTests {
    @Test func percentiles() {
        #expect(Stats.percentile([1], 0.9) == 1)
        #expect(Stats.percentile([1, 2, 3, 4, 5], 0.5) == 3)
        #expect(Stats.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(Stats.percentile([0, 10], 0.9) == 9)
        #expect(Stats.percentiles([]) == nil)
        #expect(Stats.percentiles([3, 1, 2])?.max == 3)
    }

    func record(_ index: Int, start: Double, end: Double, ok: Bool = true, tokens: Int = 10) -> Record {
        var record = Record(index: index, image: 0, start: start, end: end)
        record.ok = ok
        record.error = ok ? nil : "HTTP 500: broken"
        record.completionTokens = ok ? tokens : nil
        record.model = ok ? "m" : nil
        return record
    }

    @Test func steadyStateWindowSkipsWarmup() throws {
        // Two at once, each taking 10 s: completions at 10, 10, 20, 20, 30, 30.
        let records = (0..<6).map { record($0, start: Double($0 / 2) * 10, end: Double($0 / 2 + 1) * 10) }
        let summary = Summary.make(records, warmup: 2)
        #expect(summary.ok == 6)
        #expect(summary.measured == 4)
        #expect(summary.windowSeconds == 20)
        // Four completions in 20 s.
        #expect(summary.perHour == 720)
        #expect(summary.completionTokensPerSecond == 2)
        #expect(summary.latency?.p50 == 10)
        #expect(summary.models == ["m": 6])
    }

    @Test func noWarmupMeasuresFromTheFirstStart() {
        let records = [record(0, start: 0, end: 5), record(1, start: 5, end: 10)]
        let summary = Summary.make(records, warmup: 0)
        #expect(summary.windowSeconds == 10)
        #expect(summary.perHour == 720)
    }

    @Test func failuresAreCountedAndNotMeasured() {
        let records = [record(0, start: 0, end: 5), record(1, start: 0, end: 1, ok: false),
                       record(2, start: 5, end: 10)]
        let summary = Summary.make(records, warmup: 1)
        #expect(summary.ok == 2)
        #expect(summary.failed == 1)
        #expect(summary.measured == 1)
        #expect(summary.errors == ["HTTP 500: broken": 1])
    }

    @Test func tooFewCompletionsGiveNoThroughput() {
        let summary = Summary.make([record(0, start: 0, end: 5)], warmup: 1)
        #expect(summary.perHour == nil)
        #expect(summary.measured == 0)
    }

    @Test func reportLeavesOutIdentifyingDetails() throws {
        var options = try RunOptions.parse(["--endpoint", "studio-mac.local:8080", "--images", "/Users/someone/Photos",
                                            "--prompt", "a private prompt"])
        options.token = "secret-token"
        let corpus = [CorpusImage(name: "Someone's birthday.jpg", jpeg: Data(count: 2048), width: 1, height: 1)]
        let report = Report(options: options, corpus: corpus, startedAt: Date(timeIntervalSince1970: 0),
                            machine: Machine(chip: "Apple M2", memoryGB: 24, os: "test"),
                            summary: Summary(), thermal: [:], records: [])
        let json = String(decoding: try report.json(), as: UTF8.self)
        for leak in ["studio-mac", "someone", "Someone", "birthday", "private prompt", "secret-token"] {
            #expect(!json.contains(leak), "\(leak)")
        }
        #expect(report.settings.endpoint == "remote:8080")
        #expect(report.settings.authorized)
        #expect(report.settings.meanImageKB == 2)
        #expect(Report.describe(try RunOptions.normalizeEndpoint("127.0.0.1:8080")) == "http://127.0.0.1:8080")
    }
}

@Suite struct CompareTests {
    @Test func reportsRoundTripAndTabulate() throws {
        var options = try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/x", "--concurrency", "4",
                                            "--label", "parallel 2"])
        options.model = nil
        var summary = Summary()
        summary.perHour = 812.4
        summary.latency = Percentiles(p50: 12.31, p90: 14, p99: 15, max: 16)
        let report = Report(options: options, corpus: [], startedAt: Date(timeIntervalSince1970: 0),
                            machine: Machine(chip: "Apple M2", memoryGB: 24, os: "test"), summary: summary,
                            thermal: ["nominal": 3, "serious": 1], records: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Report.self, from: report.json())
        #expect(decoded.summary == summary)
        let lines = Report.table([decoded]).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("parallel 2"))
        #expect(lines[1].contains("812"))
        #expect(lines[1].contains("12.3"))
        #expect(lines[1].hasSuffix("25%"))
    }
}
