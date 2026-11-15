import Foundation

/// A file of what happened to the mesh, one line per event, kept between
/// launches: when each host came and went, why, and what it did meanwhile.
///
/// The window and `/health` show how things stand now, and the activity
/// chart the last day, but they're gone once conflux quits. This is for
/// after the fact: a night's run that went wrong can be read the next
/// morning, and the device it went wrong on found.
///
/// Each line is a time, what it's about, and what happened:
///
///     2026-11-15T06:36:55.104-08:00  peer-8f617d7982  starting: the peer isn't answering (serving for 6h 25m)
///
/// The time is when it happened, in the device's time zone. A line can be
/// written a few seconds after its time, so lines about different hosts can
/// be slightly out of order.
///
/// Writing never blocks the caller and never fails it: a log that can't be
/// written is skipped. Past `limit` bytes the file moves aside to `.1`,
/// replacing the one before, so the two together hold at most twice that.
public final class EventLog: Sendable {
    public let url: URL
    let limit: Int
    private let queue = DispatchQueue(label: "conflux.event-log")
    private let state = Locked()

    private final class Locked: @unchecked Sendable {
        var handle: FileHandle?
        var size = 0
    }

    public init(url: URL, limit: Int = 4 << 20) {
        self.url = url
        self.limit = limit
    }

    /// `~/Library/Logs/conflux/mesh.log`, beside llama.cpp's log: in the
    /// app's container for the app. Another identity, for a second node on
    /// one Mac, gets a file of its own.
    public static func defaultURL(identity: String = "default") -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: identity == "default" ? "Logs/conflux/mesh.log" : "Logs/conflux/mesh-\(identity).log")
    }

    /// The file before this one, once it has grown past its limit.
    public var previousURL: URL { url.appendingPathExtension("1") }

    /// Adds a line about `subject`: a host's ID, `node` for this device's
    /// node, `gateway` for its gateway, or `device` for the device itself.
    public func record(_ subject: String, _ message: String, at date: Date = Date()) {
        let line = Self.line(subject, message, at: date)
        queue.async { [self] in write(line) }
    }

    /// Returns once every line recorded before it is written.
    public func flush() { queue.sync {} }

    static func line(_ subject: String, _ message: String, at date: Date) -> String {
        let time = date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true,
                                                          timeZone: .current))
        // One event, one line, whatever a message carries.
        let flat = message.replacing("\r", with: " ").replacing("\n", with: " ")
        return "\(time)  \(subject)  \(flat)\n"
    }

    /// The log as text, the file before it first, for `conflux log`.
    public func read() -> String {
        flush()
        return [previousURL, url].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private func write(_ line: String) {
        let data = Data(line.utf8)
        if state.handle == nil { open() }
        if state.size > 0, state.size + data.count > limit {
            try? state.handle?.close()
            state.handle = nil
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.moveItem(at: url, to: previousURL)
            open()
        }
        guard let handle = state.handle else { return }
        do {
            try handle.write(contentsOf: data)
            state.size += data.count
        } catch {
            // Gone or full: try again with the next line.
            try? handle.close()
            state.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        state.handle = handle
        state.size = Int((try? handle.seekToEnd()) ?? 0)
    }
}

extension EventLog {
    /// "6h 25m", "3m 10s", "5m", "42s": how long a state lasted.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (days, hours, minutes, secs) = (total / 86400, total % 86400 / 3600, total % 3600 / 60, total % 60)
        if days > 0 { return hours == 0 ? "\(days)d" : "\(days)d \(hours)h" }
        if hours > 0 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        if minutes > 0 { return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
