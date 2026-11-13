import Foundation

/// What one host did in one minute: requests completed and failed, and the
/// tokens they read and wrote. For the status charts.
public struct ActivityMinute: Sendable, Equatable {
    /// Minutes since 1970.
    public var minute: Int
    public var completed = 0
    /// Requests that failed because of the host: it didn't answer, or its
    /// runtime answered with a server error.
    public var failed = 0
    /// Tokens read: the prompt, images included.
    public var promptTokens = 0
    /// Tokens written.
    public var completionTokens = 0
    /// Seconds spent writing the completion tokens, from the runtime's
    /// timings. Zero when it doesn't say.
    public var writingSeconds: Double = 0

    public init(minute: Int, completed: Int = 0, failed: Int = 0, promptTokens: Int = 0, completionTokens: Int = 0,
                writingSeconds: Double = 0) {
        self.minute = minute
        self.completed = completed
        self.failed = failed
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.writingSeconds = writingSeconds
    }

    public var start: Date { Date(timeIntervalSince1970: Double(minute) * 60) }

    public static func minute(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }
}

/// A host's last day, by the minute, oldest first. Minutes with nothing in
/// them aren't kept.
public struct ActivityLog: Sendable, Equatable {
    /// A day.
    public static let minutesKept = 24 * 60

    public private(set) var minutes: [ActivityMinute] = []

    public init() {}

    mutating func record(at date: Date = Date(), _ change: (inout ActivityMinute) -> Void) {
        let minute = ActivityMinute.minute(of: date)
        // Nearly always the last minute or a new one after it. A clock set
        // back puts it earlier: it goes where it sorts.
        let index = minutes.lastIndex { $0.minute <= minute } ?? -1
        if index >= 0, minutes[index].minute == minute {
            change(&minutes[index])
        } else {
            var new = ActivityMinute(minute: minute)
            change(&new)
            minutes.insert(new, at: index + 1)
        }
        let oldest = minute - Self.minutesKept
        if let first = minutes.first, first.minute <= oldest {
            minutes.removeAll { $0.minute <= oldest }
        }
    }

    mutating func completed(_ usage: Usage?, at date: Date = Date()) {
        record(at: date) {
            $0.completed += 1
            if let usage {
                $0.promptTokens += usage.prompt
                $0.completionTokens += usage.completion
                $0.writingSeconds += usage.writingSeconds
            }
        }
    }

    mutating func failed(at date: Date = Date()) {
        record(at: date) { $0.failed += 1 }
    }

    /// The minutes from `date` on.
    public func since(_ date: Date) -> [ActivityMinute] {
        let first = ActivityMinute.minute(of: date)
        return minutes.filter { $0.minute >= first }
    }
}

/// Minutes added up.
public struct ActivityTotals: Sendable, Equatable {
    public var completed = 0
    public var failed = 0
    public var promptTokens = 0
    public var completionTokens = 0
    public var writingSeconds: Double = 0

    public init<S: Sequence>(_ minutes: S) where S.Element == ActivityMinute {
        for m in minutes {
            completed += m.completed
            failed += m.failed
            promptTokens += m.promptTokens
            completionTokens += m.completionTokens
            writingSeconds += m.writingSeconds
        }
    }

    /// Tokens written per second while writing, one request's speed rather
    /// than the host's: nil until a runtime has said how long it took.
    public var tokensPerSecond: Double? {
        writingSeconds > 0 ? Double(completionTokens) / writingSeconds : nil
    }
}

/// The token counts in a chat completion response, and the time spent
/// writing from llama.cpp's `timings`, which both runtimes send.
struct Usage: Equatable {
    var prompt: Int
    var completion: Int
    var writingSeconds: Double

    init(prompt: Int, completion: Int, writingSeconds: Double) {
        self.prompt = prompt
        self.completion = completion
        self.writingSeconds = writingSeconds
    }

    init?(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        completion = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
        let timings = object["timings"] as? [String: Any]
        writingSeconds = max(0, ((timings?["predicted_ms"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    }
}
