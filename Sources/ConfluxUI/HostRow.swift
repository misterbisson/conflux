import ConfluxCore
import SwiftUI

/// One host, as this device's scheduler sees it: its rate, and below, its
/// counts and times. Shown beside the host it's about, under its model's
/// settings or its device's row. A peer's host that leaves and comes back
/// keeps its counts, and says how often it has.
public struct HostRow: View {
    let host: HostSnapshot
    let title: String
    /// Whether to name the device it runs on, where nothing beside it does.
    let hardware: Bool

    public init(_ host: HostSnapshot, title: String, hardware: Bool) {
        self.host = host
        self.title = title
        self.hardware = hardware
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Int(host.perHour.rounded())) per hour").monospacedDigit()
            }
            Text(Self.details(host, hardware: hardware)).font(Self.captionFont).foregroundStyle(.secondary)
            // Why, which the counts don't say, so it can be read here rather
            // than on the device that failed.
            if let failure = host.lastFailure {
                Text("Last failure \(failure.summary())")
                    .font(Self.captionFont).foregroundStyle(.secondary).lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .help("Over the last ten minutes, where it gives a rate, a share or a time")
    }

    public static func details(_ host: HostSnapshot, hardware: Bool) -> String {
        [hardware ? host.hardware?.summary : nil,
         "\(host.completed) completed",
         host.utilization.map { "\(percent($0)) busy" },
         host.typicalSeconds.map {
             String(format: "typical %.1f s", $0)
                 + (host.requestSeconds.map { String(format: ", p95 %.1f s", $0.p95) } ?? "")
         },
         "idle with work \(Counts.seconds(host.idleWithWorkSeconds))",
         host.prefetched > 0 ? "\(host.prefetched) sent ahead" : nil,
         host.failures.total > 0 ? Counts.describe(host.failures) : nil,
         host.declined.total > 0 ? "declined \(Counts.describe(host.declined))" : nil,
         // A device's own hosts leave and come back with Stop and Start.
         host.rejoined > 0 && host.id.hasPrefix("peer-")
             ? "rejoined \(host.rejoined) \(host.rejoined == 1 ? "time" : "times")" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    #if os(macOS)
    static var captionFont: Font { .caption }
    #else
    static var captionFont: Font { .footnote }
    #endif
}

/// How the window words what a scheduler counted.
public enum Counts {
    public static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : String(format: "%.0f s", value)
    }

    /// Requests waiting now, and how long they waited lately.
    public static func waiting(queued: Int, wait: Percentiles?) -> String {
        let now = "\(queued) now"
        guard let wait else { return now }
        return "\(now) · waited \(seconds(wait.p50)) median, \(seconds(wait.p95)) p95"
    }

    /// Declines by reason, and the slot time they took.
    public static func describe(_ declined: DeclineCounts) -> String {
        let reasons = [(declined.content, "content"), (declined.length, "too long"),
                       (declined.unsupported, "unsupported")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return (reasons + [seconds(declined.seconds)]).joined(separator: ", ")
    }

    /// The mesh's declines, and how many another host then answered.
    public static func describe(_ declined: DeclineCounts, rerouted: Int) -> String {
        "\(describe(declined)) · \(rerouted) answered elsewhere"
    }

    public static func describe(_ failures: FailureCounts) -> String {
        guard failures.total > 0 else { return "none" }
        return [(failures.unavailable, "not answering"), (failures.failed, "server error"),
                (failures.busy, "busy"), (failures.deadline, "out of time")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}
