import Foundation

public enum CLI {
    public static let usage = """
    usage: conflux-bench run --endpoint URL --images DIR [options]
           conflux-bench images --out DIR [--count 32] [--size 1024] [--seed 1]
           conflux-bench compare REPORT.json...

    run: keep requests in flight against an OpenAI-compatible endpoint and
    report throughput. Set CONFLUX_TOKEN in the environment to send a bearer
    token.

      --endpoint URL       host:port, base URL, or full /v1/chat/completions URL
      --images DIR         images to send, reused in turn (jpg, png, heic, tiff)
      --concurrency N      requests in flight at once (default 1)
      --requests N         stop after N requests (default: warmup + max(20, 10 × concurrency))
      --duration SECONDS   or stop sending new requests after this long
      --warmup N           completions left out of throughput (default: concurrency)
      --prompt TEXT        prompt sent with every image
      --prompt-file PATH   or read the prompt from a file
      --max-tokens N       completion limit per request (default 256)
      --max-dimension PX   downscale images to this longer side (default 1024)
      --limit N            load at most N images (default 200)
      --model ID           model to request (default: let the server choose)
      --timeout SECONDS    per-request timeout (default 120)
      --json PATH          also write the full report as JSON
      --save-answers PATH  write each answer as a JSON line: image, model, answer
      --label TEXT         a name for this run, kept in the report

    images: write generated test images that contain nothing personal.

    compare: one line per JSON report from `run --json`, for comparing runs.
    """

    public static func main(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 64
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "run": return try await run(rest)
            case "images": return try images(rest)
            case "compare": return try compare(rest)
            case "help", "-h", "--help":
                print(usage)
                return 0
            default: throw BenchError("unknown command: \(command)")
            }
        } catch let error as BenchError {
            standardError("conflux-bench: \(error)\n\n\(usage)\n")
            return 64
        } catch {
            standardError("conflux-bench: \(error.localizedDescription)\n")
            return 1
        }
    }

    static func run(_ args: [String]) async throws -> Int32 {
        let options = try RunOptions.parse(args, environment: ProcessInfo.processInfo.environment)
        let corpus = try Corpus.load(from: options.images, maxDimension: options.maxDimension, limit: options.limit)
        standardError("loaded \(corpus.count) images; sending to \(options.chatURL.absoluteString)\n")

        let total = options.effectiveRequests
        let runner = Runner(options: options, corpus: corpus) { record in
            let of = total.map { "/\($0)" } ?? ""
            let outcome = record.ok ? "ok" : (record.error ?? "failed")
            standardError(String(format: "[%d%@] %.1f s  %@\n", record.index + 1, of, record.latency, outcome))
        }
        let thermal = ThermalLog()
        let sampling = await thermal.sample()
        let startedAt = Date()
        let swapBefore = Machine.swapUsedMB()
        let records = await runner.run()
        sampling.cancel()

        var report = Report(options: options, corpus: corpus, startedAt: startedAt, machine: .current,
                            summary: Summary.make(records, warmup: options.effectiveWarmup),
                            thermal: await thermal.samples, records: records)
        if let swapBefore, let swapAfter = Machine.swapUsedMB() { report.swapMB = [swapBefore, swapAfter] }
        print(report.text)
        if let path = options.jsonPath {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try report.json().write(to: url)
            standardError("wrote \(path)\n")
        }
        if let path = options.answersPath {
            try writeAnswers(records, to: path)
            standardError("wrote \(path)\n")
        }
        return report.summary.ok > 0 ? 0 : 1
    }

    /// One line per answered request, in request order, so two runs over the
    /// same images can be compared line by line.
    static func writeAnswers(_ records: [Record], to path: String) throws {
        let lines = try records.filter(\.ok).map { record -> String in
            let object: [String: Any] = ["image": record.image, "model": record.model ?? "",
                                         "answer": record.answer ?? ""]
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                          as: UTF8.self)
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    static func images(_ args: [String]) throws -> Int32 {
        var out: String?
        var count = 32, size = 1024
        var seed: UInt64 = 1
        var index = 0
        while index < args.count {
            guard index + 1 < args.count else { throw BenchError("\(args[index]) needs a value") }
            let value = args[index + 1]
            switch args[index] {
            case "--out": out = value
            case "--count":
                guard let n = Int(value), n > 0 else { throw BenchError("--count must be at least 1") }
                count = n
            case "--size":
                guard let n = Int(value), n >= 64 else { throw BenchError("--size must be at least 64") }
                size = n
            case "--seed":
                guard let n = UInt64(value) else { throw BenchError("--seed must be a whole number") }
                seed = n
            default: throw BenchError("unknown option: \(args[index])")
            }
            index += 2
        }
        guard let out else { throw BenchError("--out is required") }
        let urls = try SyntheticImages.write(count: count, size: size, seed: seed,
                                             to: URL(fileURLWithPath: out))
        print("wrote \(urls.count) images to \(out)")
        return 0
    }

    static func compare(_ paths: [String]) throws -> Int32 {
        guard !paths.isEmpty else { throw BenchError("compare needs at least one report") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reports = try paths.map { path in
            do {
                return try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw BenchError("can't read \(path) as a report: \(error.localizedDescription)")
            }
        }
        print(Report.table(reports))
        return 0
    }

    static func standardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
