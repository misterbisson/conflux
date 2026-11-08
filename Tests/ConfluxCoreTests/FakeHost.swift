import Foundation
@testable import ConfluxCore

/// A host whose behavior each test scripts: how long a request takes, and
/// what it answers or throws.
final class FakeHost: InferenceHost, @unchecked Sendable {
    let id: String
    let slots: Int
    private let lock = NSLock()
    private var info: ModelInfo?
    private var state: HostAvailability
    private var running = 0
    private(set) var peak = 0
    private(set) var calls = 0
    private var reported: HostReport?
    private var aheadCount = 0
    var behavior: @Sendable (Int) async throws -> HostReply

    init(id: String, model: String = "model-a", capabilities: Set<ModelInfo.Capability> = [.text, .vision],
         slots: Int = 1, availability: HostAvailability = .available,
         behavior: @escaping @Sendable (Int) async throws -> HostReply = FakeHost.reply(after: 0)) {
        self.id = id
        self.slots = slots
        info = ModelInfo(id: model, capabilities: capabilities, fingerprint: "fake-\(model)", maxImageDimension: 1024)
        state = availability
        self.behavior = behavior
    }

    var model: ModelInfo? { get async { lock.withLock { info } } }
    var availability: HostAvailability { get async { lock.withLock { state } } }

    func set(_ availability: HostAvailability) { lock.withLock { state = availability } }
    /// Makes this host report on its slots, like a host on another device.
    func report(free: Int = 0, freeSeconds: Double? = nil, pulls: Bool = false, at: Date = Date()) {
        lock.withLock { reported = HostReport(free: free, freeSeconds: freeSeconds, pulls: pulls, at: at) }
    }
    var report: HostReport? { get async { lock.withLock { reported } } }
    /// Requests sent to it ahead, to wait for a slot.
    var prefetchCount: Int { lock.withLock { aheadCount } }

    func complete(_ body: Data, timeout: TimeInterval, options: RequestOptions) async throws -> HostReply {
        if options.prefetch { lock.withLock { aheadCount += 1 } }
        return try await complete(body, timeout: timeout)
    }
    var callCount: Int { lock.withLock { calls } }
    var peakConcurrency: Int { lock.withLock { peak } }

    func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
        let call = lock.withLock { () -> Int in
            calls += 1
            running += 1
            peak = max(peak, running)
            return calls
        }
        defer { lock.withLock { running -= 1 } }
        return try await behavior(call)
    }

    static let okBody = Data(#"{"choices":[{"message":{"content":"fine"}}],"model":"whatever.gguf"}"#.utf8)

    static func reply(after seconds: Double, status: Int = 200, body: Data = okBody)
        -> @Sendable (Int) async throws -> HostReply {
        { _ in
            if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
            return HostReply(status: status, body: body)
        }
    }
}

extension Scheduler {
    static func with(_ hosts: [FakeHost], config: SchedulerConfig = SchedulerConfig()) async -> Scheduler {
        let scheduler = Scheduler(config: config)
        for host in hosts { await scheduler.add(host) }
        return scheduler
    }
}

/// Waits until `condition` holds, checking every 10 ms, for up to `seconds`.
/// Returns whether it came to hold. Tests wait on state this way, not for a
/// fixed time, so a slow machine only makes them slower.
func eventually(within seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
