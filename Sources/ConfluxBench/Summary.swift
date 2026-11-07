import Foundation

public struct Percentiles: Sendable, Codable, Equatable {
    public var p50: Double
    public var p90: Double
    public var p99: Double
    public var max: Double
}

public enum Stats {
    /// Linear interpolation between closest ranks. `sorted` must be ascending
    /// and non-empty, and `p` is in [0, 1].
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        precondition(!sorted.isEmpty)
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    public static func percentiles(_ values: [Double]) -> Percentiles? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Percentiles(p50: percentile(sorted, 0.5), p90: percentile(sorted, 0.9),
                           p99: percentile(sorted, 0.99), max: sorted[sorted.count - 1])
    }

    public static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// What a run amounts to.
///
/// Throughput is measured over a **steady-state window**. It starts when the
/// `warmup`th request completes and ends when the last one does, so the ramp
/// at the start doesn't drag the figure down. Requests in flight when the
/// window opens still count if they finish inside it, which is what a server
/// delivers in steady state.
public struct Summary: Sendable, Codable, Equatable {
    public var ok = 0
    public var failed = 0
    public var busyRetries = 0
    /// Completions inside the window.
    public var measured = 0
    public var windowSeconds: Double?
    public var perHour: Double?
    /// Latency of the measured requests, in seconds, as the client saw it.
    public var latency: Percentiles?
    public var meanPromptTokens: Double?
    public var meanCompletionTokens: Double?
    public var meanPromptMs: Double?
    public var meanPredictedMs: Double?
    /// Generated tokens per second across all requests in the window.
    public var completionTokensPerSecond: Double?
    public var models: [String: Int] = [:]
    public var fingerprints: [String: Int] = [:]
    public var errors: [String: Int] = [:]

    public static func make(_ records: [Record], warmup: Int) -> Summary {
        var summary = Summary()
        let succeeded = records.filter(\.ok).sorted { $0.end < $1.end }
        summary.ok = succeeded.count
        summary.failed = records.count - succeeded.count
        summary.busyRetries = records.reduce(0) { $0 + $1.busyRetries }
        for record in records where !record.ok {
            summary.errors[String((record.error ?? "unknown").prefix(80)), default: 0] += 1
        }
        for record in succeeded {
            summary.models[record.model ?? "(not reported)", default: 0] += 1
            summary.fingerprints[record.fingerprint ?? "(not reported)", default: 0] += 1
        }

        guard succeeded.count > warmup, let last = succeeded.last else { return summary }
        let measured = Array(succeeded.dropFirst(warmup))
        let windowStart = warmup > 0 ? succeeded[warmup - 1].end : (records.map(\.start).min() ?? 0)
        let window = last.end - windowStart
        summary.measured = measured.count
        summary.latency = Stats.percentiles(measured.map(\.latency))
        summary.meanPromptTokens = Stats.mean(measured.compactMap(\.promptTokens).map(Double.init))
        summary.meanCompletionTokens = Stats.mean(measured.compactMap(\.completionTokens).map(Double.init))
        summary.meanPromptMs = Stats.mean(measured.compactMap(\.promptMs))
        summary.meanPredictedMs = Stats.mean(measured.compactMap(\.predictedMs))
        if window > 0 {
            summary.windowSeconds = window
            summary.perHour = Double(measured.count) / window * 3600
            let tokens = measured.compactMap(\.completionTokens).reduce(0, +)
            if tokens > 0 { summary.completionTokensPerSecond = Double(tokens) / window }
        }
        return summary
    }
}
