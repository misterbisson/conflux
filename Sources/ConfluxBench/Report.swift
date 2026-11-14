import CryptoKit
import Foundation
#if os(macOS)
import IOKit
#endif

/// The machine running the benchmark: chip, GPU cores, memory and OS only,
/// never a hostname or serial number. When the server is on the same
/// machine, this is the server too.
public struct Machine: Sendable, Codable, Equatable {
    public var chip: String
    /// Nil where the system doesn't say, and in reports from before it was
    /// recorded.
    public var gpuCores: Int?
    public var memoryGB: Int
    public var os: String

    public init(chip: String, gpuCores: Int? = nil, memoryGB: Int, os: String) {
        self.chip = chip
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.os = os
    }

    public static var current: Machine {
        Machine(chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                gpuCores: gpuCoreCount(),
                memoryGB: Int((sysctlUInt64("hw.memsize") ?? 0) / 1_073_741_824),
                os: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// `Apple M4 Pro, 16-core GPU, 48 GB`.
    public var description: String {
        [chip, gpuCores.map { "\($0)-core GPU" }, "\(memoryGB) GB"].compactMap { $0 }.joined(separator: ", ")
    }

    /// The GPU's `gpu-core-count`, from IOKit's accelerator.
    static func gpuCoreCount() -> Int? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
        #else
        return nil
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Swap in use, in MB. Growth during a run means the machine was short of
    /// memory, and its numbers measure the disk more than the model.
    public static func swapUsedMB() -> Int? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int(usage.xsu_used / 1_048_576)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

/// Thermal state of this machine, sampled during a run. Fanless machines
/// throttle under sustained load, and burst numbers hide that.
public actor ThermalLog {
    private var counts: [String: Int] = [:]
    public init() {}
    func add(_ state: String) { counts[state, default: 0] += 1 }
    public var samples: [String: Int] { counts }

    public static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    public func sample(every interval: Duration = .seconds(5)) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                add(Self.name(ProcessInfo.processInfo.thermalState))
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// A run's JSON record. It leaves out what could identify a person or a
/// device: no image file names or directory, no prompt text (only its length
/// and hash), no server host unless it's loopback, no token.
public struct Report: Sendable, Codable {
    public struct Settings: Sendable, Codable, Equatable {
        public var endpoint: String
        public var concurrency: Int
        public var requests: Int?
        public var duration: Double?
        public var warmup: Int
        public var maxTokens: Int
        public var maxDimension: Int
        public var images: Int
        public var meanImageKB: Double
        public var promptCharacters: Int
        public var promptSHA256: String
        public var model: String?
        public var authorized: Bool
    }

    public var tool = "conflux-bench"
    public var label: String?
    public var startedAt: Date
    public var machine: Machine
    public var settings: Settings
    public var summary: Summary
    public var thermal: [String: Int]
    /// Swap in use at the start and end of the run, in MB.
    public var swapMB: [Int]?
    public var records: [Record]

    public init(options: RunOptions, corpus: [CorpusImage], startedAt: Date, machine: Machine,
                summary: Summary, thermal: [String: Int], records: [Record]) {
        self.label = options.label
        self.startedAt = startedAt
        self.machine = machine
        self.summary = summary
        self.thermal = thermal
        self.swapMB = nil
        self.records = records
        let digest = SHA256.hash(data: Data(options.prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        settings = Settings(
            endpoint: Report.describe(options.endpoint),
            concurrency: options.concurrency, requests: options.effectiveRequests,
            duration: options.duration, warmup: options.effectiveWarmup,
            maxTokens: options.maxTokens, maxDimension: options.maxDimension,
            images: corpus.count,
            meanImageKB: corpus.isEmpty ? 0 : Double(corpus.map(\.jpeg.count).reduce(0, +)) / Double(corpus.count) / 1024,
            promptCharacters: options.prompt.count, promptSHA256: digest,
            model: options.model, authorized: options.token != nil)
    }

    /// Loopback endpoints are named in full. Anything else is reduced to
    /// "remote" and its port.
    static func describe(_ endpoint: URL) -> String {
        let host = endpoint.host ?? ""
        let port = endpoint.port.map { ":\($0)" } ?? ""
        if ["127.0.0.1", "localhost", "::1"].contains(host) { return endpoint.absoluteString }
        return "remote\(port)"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public var text: String {
        let s = summary
        var lines: [String] = []
        func line(_ name: String, _ value: String) {
            lines.append(name.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
        }
        func f(_ value: Double?, _ digits: Int = 1) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "–"
        }

        lines.append("conflux-bench" + (label.map { "  \($0)" } ?? ""))
        line("endpoint", settings.endpoint)
        line("machine", machine.description)
        line("load", "\(settings.concurrency) concurrent, \(settings.images) images at ≤\(settings.maxDimension) px "
            + "(\(f(settings.meanImageKB, 0)) KB avg)")
        line("requests", "\(s.ok) ok, \(s.failed) failed, \(s.busyRetries) busy retries")
        line("throughput", s.perHour.map { "\(f($0, 0)) per hour (\(s.measured) after \(settings.warmup) warmup, "
            + "over \(f(s.windowSeconds, 0)) s)" } ?? "– (too few completions after warmup)")
        if let latency = s.latency {
            line("latency", "p50 \(f(latency.p50)) s   p90 \(f(latency.p90)) s   p99 \(f(latency.p99)) s   "
                + "max \(f(latency.max)) s")
        }
        line("tokens", "prompt \(f(s.meanPromptTokens, 0)) avg   completion \(f(s.meanCompletionTokens, 0)) avg   "
            + "\(f(s.completionTokensPerSecond)) generated/s total")
        if s.meanPromptMs != nil || s.meanPredictedMs != nil {
            line("server", "reading prompt \(f(s.meanPromptMs.map { $0 / 1000 })) s avg   "
                + "generating \(f(s.meanPredictedMs.map { $0 / 1000 })) s avg")
        }
        line("models", s.models.isEmpty ? "–"
            : s.models.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        let total = thermal.values.reduce(0, +)
        if total > 0 {
            let order = ["nominal", "fair", "serious", "critical", "unknown"]
            line("thermal", order.compactMap { state in
                thermal[state].map { "\(state) \(Int((Double($0) / Double(total) * 100).rounded()))%" }
            }.joined(separator: "   ") + "   (this machine)")
        }
        if let swap = swapMB, swap.count == 2 {
            let growth = swap[1] - swap[0]
            line("swap", "\(swap[0]) MB at start, \(growth >= 0 ? "+" : "")\(growth) MB during the run"
                + (growth > 256 ? "   ⚠ short of memory: these numbers are suspect" : ""))
        }
        for (error, count) in s.errors.sorted(by: { $0.value > $1.value }).prefix(5) {
            line("error", "×\(count) \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// One row per report: the figures that decide slot counts.
    public static func table(_ reports: [Report]) -> String {
        func f(_ value: Double?, _ digits: Int = 0) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "–"
        }
        let header = ["run", "in flight", "per hour", "p50 s", "p90 s", "gen tok/s", "failed", "hot", "swap +MB"]
        let rows = reports.map { report -> [String] in
            let s = report.summary
            let samples = report.thermal.values.reduce(0, +)
            let hot = samples == 0 ? nil
                : Double((report.thermal["serious"] ?? 0) + (report.thermal["critical"] ?? 0)) / Double(samples) * 100
            return [report.label ?? report.startedAt.formatted(.iso8601), String(report.settings.concurrency),
                    f(s.perHour), f(s.latency?.p50, 1), f(s.latency?.p90, 1), f(s.completionTokensPerSecond, 1),
                    String(s.failed), hot.map { f($0) + "%" } ?? "–",
                    report.swapMB.flatMap { $0.count == 2 ? String($0[1] - $0[0]) : nil } ?? "–"]
        }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, cell in
                column == 0 ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - cell.count) + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
