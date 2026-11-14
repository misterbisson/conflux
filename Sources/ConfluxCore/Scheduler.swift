import Foundation

/// What became of one request.
public enum Outcome: Sendable, Equatable {
    /// The runtime answered successfully. `model` is what ran.
    case completed(HostReply, model: ModelInfo)
    /// The runtime refused the request itself (a 4xx). Passed on, naming
    /// `model`, the model that refused. When several declined, it's the last.
    case rejected(HostReply, model: ModelInfo)
    /// No slot in time: 429.
    case busy(retryAfter: Int)
    /// Hosts failed and time ran out, or no host for an accepted model is up: 503.
    case unavailable(retryAfter: Int, message: String)
    /// No host has served a model this request accepts: 404.
    case unknownModel(String)
    /// Whoever sent it cancelled it: another device's gateway, for a hedged
    /// copy that lost, or a client that closed its connection, which isn't
    /// there to read the answer.
    case cancelled
}

public struct SchedulerConfig: Sendable {
    /// How long a request without a deadline may wait for a slot.
    public var defaultQueueWait: TimeInterval = 30
    /// The longest a request without a deadline may run.
    public var maxExecution: TimeInterval = 600
    /// Answer this long before a client's deadline, so the answer arrives in time.
    public var margin: TimeInterval = 1
    /// How long a finished result is kept for clients that retry with the same key.
    public var idempotencyTTL: TimeInterval = 900
    public var idempotencyCapacity = 1000
    /// Send one request ahead to fast hosts on other devices, to wait there
    /// for their next free slot, so the slot doesn't sit idle for a round
    /// trip (docs/design.md, *Hosts pull*).
    public var prefetch = true
    /// A host is fast enough to take a request ahead when its typical time is
    /// at most this many times the quickest compatible host's...
    public var prefetchFactor = 1.5
    /// ...and at most this many seconds. A round trip matters less against
    /// a long request, and a request waiting behind one is held back longer.
    public var prefetchUpTo: TimeInterval = 20
    /// At the tail of a batch, when nothing waits, send a copy of a request
    /// that has run well past its host's typical time to an idle host, take
    /// the first answer, and cancel the other (docs/design.md, *Failures and
    /// stragglers*).
    public var hedge = true
    /// Well past is this many times the host's typical time.
    public var hedgeAfter = 2.0

    public init() {}
}

/// How the person running a host wants it to behave.
public enum OwnerIntent: String, Sendable, Codable {
    case serving
    /// Finish what's running, take nothing new.
    case draining
    /// Take nothing new.
    case paused
}

/// The state a host is in, as the design defines it.
public enum HostState: Sendable, Equatable {
    case ready
    case busy
    case draining
    case paused(String)
    case starting(String)
    case failed(String)
    case offline

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .busy: "Busy"
        case .draining: "Draining"
        case .paused: "Paused"
        case .starting: "Starting"
        case .failed: "Failed"
        case .offline: "Offline"
        }
    }

    public var detail: String? {
        switch self {
        case .paused(let why), .starting(let why), .failed(let why): why
        default: nil
        }
    }
}

/// What went wrong with requests sent to hosts, by kind.
public struct FailureCounts: Sendable, Equatable {
    /// Nothing answered: refused, reset, timed out, or the host was lost.
    public var unavailable = 0
    /// The runtime answered with a server error.
    public var failed = 0
    /// The host had no free slot when the request reached it: another
    /// gateway took it first. Not the host's fault.
    public var busy = 0
    /// The client's deadline passed while the request ran. Not the host's
    /// fault either.
    public var deadline = 0

    public init(unavailable: Int = 0, failed: Int = 0, busy: Int = 0, deadline: Int = 0) {
        self.unavailable = unavailable
        self.failed = failed
        self.busy = busy
        self.deadline = deadline
    }

    /// The ones that count against a host: not answering, and server errors.
    public var hostFaults: Int { unavailable + failed }
    public var total: Int { unavailable + failed + busy + deadline }

    mutating func record(_ error: HostError, outOfTime: Bool) {
        switch error {
        case _ where outOfTime: deadline += 1
        case .busy: busy += 1
        case .unavailable: unavailable += 1
        case .failed: failed += 1
        case .cancelled: break
        }
    }
}

public struct HostSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var model: ModelInfo?
    public var state: HostState
    public var slots: Int
    public var capacity: Int
    public var active: Int
    public var completed: Int
    public var failures: FailureCounts
    /// Smoothed seconds per request, once there's history.
    public var typicalSeconds: Double?
    /// Completions in the last ten minutes, scaled to an hour.
    public var perHour: Double
    /// Seconds this host had a free slot while work it could run waited at
    /// this gateway. Should stay near zero.
    public var idleWithWorkSeconds: Double
    /// Seconds this host has had a free slot at all, by its own count. A
    /// host reports it to peers' gateways, which can't see its slots.
    public var freeSeconds: Double
    /// Requests sent ahead and waiting for a slot: on this Mac's host, from
    /// peers' gateways; on a peer's, as it last said.
    public var held: Int
    /// Requests sent ahead: to a peer's host by this gateway, or taken ahead
    /// by this Mac's host.
    public var prefetched: Int
    /// What kind of device it runs on, when known.
    public var hardware: HardwareInfo?

    public init(id: String, model: ModelInfo? = nil, state: HostState, slots: Int = 0, capacity: Int = 0,
                active: Int = 0, completed: Int = 0, failures: FailureCounts = FailureCounts(),
                typicalSeconds: Double? = nil, perHour: Double = 0, idleWithWorkSeconds: Double = 0,
                freeSeconds: Double = 0, held: Int = 0, prefetched: Int = 0, hardware: HardwareInfo? = nil) {
        self.id = id
        self.model = model
        self.state = state
        self.slots = slots
        self.capacity = capacity
        self.active = active
        self.completed = completed
        self.failures = failures
        self.typicalSeconds = typicalSeconds
        self.perHour = perHour
        self.idleWithWorkSeconds = idleWithWorkSeconds
        self.freeSeconds = freeSeconds
        self.held = held
        self.prefetched = prefetched
        self.hardware = hardware
    }

    /// Requests that failed because of the host.
    public var failed: Int { failures.hostFaults }
}

public struct SchedulerSnapshot: Sendable, Equatable {
    public var hosts: [HostSnapshot]
    public var queued: Int
    /// Requests this gateway completed, on any host.
    public var completed: Int
    /// What went wrong with requests this gateway sent to hosts. Most were
    /// retried on another host.
    public var failures: FailureCounts
    /// Answers passed on from runtimes that refused a request (4xx).
    public var rejected: Int
    /// Answers of 429: no slot in time.
    public var busy: Int
    /// Answers of 503: hosts failed and time ran out, or none was up.
    public var unavailable: Int
    /// Copies of requests sent to an idle host at the tail of a batch.
    public var hedged: Int
    /// Copies that answered first.
    public var hedgeWins: Int
    /// This gateway's completions in the last ten minutes, scaled to an hour.
    public var perHour: Double
    /// The hosts' idle-with-work seconds, added up: seconds of a host with a
    /// free slot sitting idle while work it could run waited here. Should
    /// stay near zero.
    public var idleWithWorkSeconds: Double

    /// Requests that failed because of a host.
    public var failed: Int { failures.hostFaults }
}

/// Matches requests to hosts and keeps every slot busy while work waits.
///
/// Requests wait here only briefly, and always get an answer before their
/// deadline (docs/design.md, *Deadlines*). Hosts never get more requests than
/// they have slots, and a request is never sent to a host whose typical time
/// wouldn't fit what's left of its deadline.
public actor Scheduler {
    struct Entry {
        let host: any InferenceHost
        var model: ModelInfo?
        var availability: HostAvailability = .starting("not checked yet")
        var intent: OwnerIntent = .serving
        /// From resource policy: at most this many slots, and why.
        var limit: (slots: Int, reason: String?)?
        var active: [UUID: Date] = [:]
        var completed = 0
        var failures = FailureCounts()
        var typical: Double?
        /// When requests completed, for throughput. Ten minutes are kept.
        var recent: [Date] = []

        // Idle-with-work accounting (see `account()`). Each `…Since` is set
        // while its condition holds, and the time is added when it changes.
        /// Seconds with a free slot, as this scheduler sees the host.
        var freeTime: TimeInterval = 0
        var freeSince: Date?
        /// Seconds that work this host could run waited here.
        var waitedTime: TimeInterval = 0
        var waitedSince: Date?
        /// Seconds both held, for a host whose slots this scheduler sees.
        var idleTime: TimeInterval = 0
        var idleSince: Date?
        /// For a host on another device, which counts its own free time: the
        /// last count it reported, and `waitedTime` when it arrived.
        var freeSample: (free: Double, waited: TimeInterval, at: Date)?

        /// What a host on another device last said about its slots.
        var report: HostReport?
        /// The host said busy: it has no slot free until it says otherwise.
        var full = false
        /// When a request was last sent ahead to this host.
        var prefetchedAt: Date?
        var prefetched = 0

        var capacity: Int {
            guard intent == .serving, availability == .available, model != nil else { return 0 }
            return min(host.slots, limit?.slots ?? host.slots)
        }

        /// Slots free for this scheduler to fill. For a host on another
        /// device that does host pull, other gateways share the slots, so
        /// it's what the host last said, less what was sent since. The host
        /// says again whenever its slots change, and with each answer.
        var free: Int {
            let own = max(0, capacity - active.count)
            guard let report, report.pulls else { return own }
            if full { return 0 }
            let sent = active.values.filter { $0 > report.at }.count
            return max(0, min(own, report.free - sent))
        }

        /// Whether a request may be sent ahead to wait here: a host on
        /// another device that holds none, as far as this gateway knows.
        var canHold: Bool {
            guard let report, report.pulls, !full, capacity > 0, report.held == 0 else { return false }
            return (prefetchedAt ?? .distantPast) < report.at
        }

        var state: HostState {
            switch availability {
            case .offline: return .offline
            case .failed(let why): return .failed(why)
            case .starting(let why): return .starting(why)
            case .paused(let why): return .paused(why)
            case .available: break
            }
            switch intent {
            case .paused: return .paused("paused by its owner")
            case .draining: return active.isEmpty ? .paused("drained") : .draining
            case .serving: break
            }
            if let limit, limit.slots == 0 { return .paused(limit.reason ?? "paused by resource policy") }
            return free > 0 ? .ready : .busy
        }

        /// Exponentially weighted, so a host that warms up or throttles is
        /// tracked within a few requests.
        mutating func record(seconds: Double) {
            typical = typical.map { 0.7 * $0 + 0.3 * seconds } ?? seconds
        }
    }

    /// A slot held for one request, registered in its host's `active` set.
    struct Lease: Sendable {
        let host: String
        let id: UUID
        /// Sent ahead, to wait on the host for a slot.
        var prefetch = false
        /// May wait on the host for a slot if another gateway took the free
        /// one first: sent to a fast host. True of every request sent ahead.
        var mayWait = false
    }

    struct Waiter {
        let id: UUID
        let choice: ModelChoice
        let excluded: Set<String>
        /// Waiting for a slot on this host only: a request a peer's gateway
        /// sent ahead.
        var pinned: String?
        let remaining: () -> TimeInterval?
        let continuation: CheckedContinuation<Lease?, Never>
    }

    let config: SchedulerConfig
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var waiting: [Waiter] = []
    private var seen: [String: ModelInfo] = [:]
    /// Requests with an `Idempotency-Key` that are running, and the clients
    /// waiting for each.
    private var inFlight: [String: Shared] = [:]
    private var finished: [String: (outcome: Outcome, at: Date)] = [:]
    private var completedCount = 0, rejectedCount = 0, busyCount = 0, unavailableCount = 0
    private var failures = FailureCounts()
    private var recent: [Date] = []
    /// Each host's last day, by the minute, kept here so it outlasts hosts
    /// that leave and come back.
    private var activity: [String: ActivityLog] = [:]
    /// Every host's idle-with-work time, kept here too so it outlasts hosts
    /// that leave.
    private var idleWithWork: TimeInterval = 0
    private var refreshing: Task<Void, Never>?
    /// Each host's status changes, counted, so peers' gateways can wait for
    /// the next one (`status(of:after:wait:)`).
    private var generations: [String: Int] = [:]
    private var fingerprints: [String: String] = [:]
    private var watchers: [UUID: (host: String, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// A request that clients sending the same key share. It runs while any
    /// of them waits for it.
    struct Shared {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    }

    /// One request's copies in flight: the first, and a hedge.
    struct Attempt {
        let body: Data
        let choice: ModelChoice
        let tried: Set<String>
        let remaining: () -> TimeInterval?
        /// The first copy's lease.
        let first: UUID
        var copies: [UUID: (lease: Lease, model: ModelInfo, started: Date)] = [:]
        var hedged = false
        /// Hosts where a copy failed while another ran on.
        var failed: Set<String> = []
        let continuation: CheckedContinuation<Answer, Never>
    }

    /// The copy that settled a request, and what became of it.
    struct Answer {
        let host: String
        let model: ModelInfo
        let result: Result<HostReply, HostError>
        let failed: Set<String>
    }

    private var attempts: [UUID: Attempt] = [:]
    /// Each copy's task, by lease, to cancel the one that loses.
    private var copies: [UUID: Task<Void, Never>] = [:]
    private var hedgeCount = 0, hedgeWinCount = 0

    public init(config: SchedulerConfig = SchedulerConfig()) {
        self.config = config
    }

    // MARK: Hosts

    public func add(_ host: any InferenceHost) async {
        if entries[host.id] == nil { order.append(host.id) }
        entries[host.id] = Entry(host: host)
        let id = host.id
        host.observe { [weak self] in Task { await self?.refresh(hostID: id) } }
        await refresh()
    }

    public func remove(hostID: String) {
        entries.removeValue(forKey: hostID)
        order.removeAll { $0 == hostID }
    }

    public func setIntent(_ intent: OwnerIntent, for hostID: String) {
        entries[hostID]?.intent = intent
        dispatch()
    }

    public func setLimit(_ slots: Int?, reason: String?, for hostID: String) {
        entries[hostID]?.limit = slots.map { ($0, reason) }
        dispatch()
    }

    /// Sets a host's typical time as if it had been measured, so tests of
    /// decisions that depend on it don't depend on how fast the machine
    /// running them is. Requests that complete still update it.
    func setTypical(_ seconds: Double?, for hostID: String) {
        entries[hostID]?.typical = seconds
        dispatch()
    }

    /// Reads each host's model and availability. Runs every second once
    /// `startRefreshing` is called. Tests call it directly.
    public func refresh() async {
        for id in order { await read(id) }
        dispatch()
    }

    /// Reads one host, when it says something changed.
    func refresh(hostID: String) async {
        await read(hostID)
        dispatch()
    }

    private func read(_ id: String) async {
        guard let host = entries[id]?.host else { return }
        let model = await host.model
        let availability = await host.availability
        let report = await host.report
        entries[id]?.model = model
        entries[id]?.availability = availability
        if let model { seen[model.id] = model }
        if let report, report.at > (entries[id]?.report?.at ?? .distantPast) {
            entries[id]?.report = report
            entries[id]?.full = false
            if let seconds = report.freeSeconds { note((seconds, report.at), for: id) }
        }
    }

    public func startRefreshing(every interval: Duration = .seconds(1)) {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopRefreshing() {
        refreshing?.cancel()
        refreshing = nil
    }

    /// The models clients can ask for right now, and the ones seen before.
    public func models() -> [(model: ModelInfo, hosts: Int, serving: Int)] {
        seen.values.sorted { $0.id < $1.id }.map { model in
            let hosts = entries.values.filter { $0.model?.id == model.id }
            return (model, hosts.count, hosts.filter { $0.capacity > 0 }.count)
        }
    }

    // MARK: Requests

    /// Runs one request: finds a host, waits for a slot if it's worth
    /// waiting, retries on another host if one fails, and answers before
    /// `deadline`. Requests with the same `key` run once.
    ///
    /// Cancelling the calling task, as the gateway does when a client closes
    /// its connection, stops the request and frees its slot, and the answer
    /// is `.cancelled`. A request other clients wait for with the same key
    /// runs on for them.
    public func submit(_ body: Data, choice: ModelChoice, deadline: Date?, key: String?) async -> Outcome {
        pruneFinished()
        guard let key else { return await execute(body, choice: choice, deadline: deadline) }
        if let done = finished[key] { return done.outcome }
        if inFlight[key] == nil {
            let shared = UUID()
            let task = Task {
                let outcome = await self.execute(body, choice: choice, deadline: deadline)
                self.finish(key, shared: shared, outcome)
            }
            inFlight[key] = Shared(id: shared, task: task)
        }
        guard let shared = inFlight[key]?.id else { return .cancelled }
        let id = UUID()
        // Isolated to this actor by name, as in `enqueue`.
        return await withTaskCancellationHandler(operation: {
            await join(key, shared: shared, as: id)
        }, onCancel: {
            Task { await self.leave(key, shared: shared, as: id) }
        }, isolation: self)
    }

    private func join(_ key: String, shared: UUID, as id: UUID) async -> Outcome {
        await withCheckedContinuation { continuation in
            guard inFlight[key]?.id == shared else {
                continuation.resume(returning: finished[key]?.outcome ?? .cancelled)
                return
            }
            guard !Task.isCancelled else {
                continuation.resume(returning: .cancelled)
                stopIfUnwanted(key)
                return
            }
            inFlight[key]?.waiters[id] = continuation
        }
    }

    /// A client stopped waiting for a request it shares. The last to go
    /// cancels it, and a client that sends the key after that starts it again.
    private func leave(_ key: String, shared: UUID, as id: UUID) {
        guard inFlight[key]?.id == shared, let waiter = inFlight[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: .cancelled)
        stopIfUnwanted(key)
    }

    /// How many clients wait for the request running with this key.
    func clients(waitingFor key: String) -> Int { inFlight[key]?.waiters.count ?? 0 }

    private func stopIfUnwanted(_ key: String) {
        guard let shared = inFlight[key], shared.waiters.isEmpty else { return }
        inFlight[key] = nil
        shared.task.cancel()
    }

    private func finish(_ key: String, shared: UUID, _ outcome: Outcome) {
        switch outcome {
        case .completed, .rejected:
            finished[key] = (outcome, Date())
        default:
            break // Worth trying again: don't remember.
        }
        // Unless every client left, and it was cancelled and forgotten.
        guard let running = inFlight[key], running.id == shared else { return }
        inFlight[key] = nil
        for waiter in running.waiters.values { waiter.resume(returning: outcome) }
    }

    func execute(_ body: Data, choice: ModelChoice, deadline: Date?) async -> Outcome {
        func remaining() -> TimeInterval? { deadline.map { $0.timeIntervalSinceNow - config.margin } }

        let eligible = entries.values.filter { $0.model.map { choice.rank($0) != nil } ?? false }
        // Stop waiting once there'd be no time left to run on even the
        // fastest eligible host.
        let quickest = eligible.compactMap(\.typical).min() ?? 0
        let queueUntil = deadline.map { $0.addingTimeInterval(-config.margin - quickest) }
            ?? Date().addingTimeInterval(config.defaultQueueWait)
        if eligible.isEmpty {
            if seen.values.contains(where: { choice.rank($0) != nil }) {
                return unavailable(retryAfter: 30, "no host serving an accepted model is running")
            }
            return .unknownModel(describe(choice))
        }
        if !eligible.contains(where: { $0.capacity > 0 || !$0.active.isEmpty }) {
            let starting = eligible.contains { if case .starting = $0.availability { true } else { false } }
            let why = eligible.compactMap { $0.state.detail }.first ?? "no host is taking work"
            return unavailable(retryAfter: starting ? 5 : 30, why)
        }

        var tried: Set<String> = []
        while true {
            // Its client has gone: no one would read the answer.
            if Task.isCancelled { return .cancelled }
            guard let lease = await acquire(choice: choice, excluding: tried, until: queueUntil, remaining: remaining)
            else {
                if Task.isCancelled { return .cancelled }
                busyCount += 1
                return .busy(retryAfter: estimateWait(choice))
            }
            guard let model = entries[lease.host]?.model else {
                entries[lease.host]?.active[lease.id] = nil
                tried.insert(lease.host)
                continue
            }
            let answer = await attempt(body, lease: lease, model: model, choice: choice, tried: tried,
                                       remaining: remaining)
            tried.formUnion(answer.failed)
            let hostID = answer.host
            switch answer.result {
            case .success(let reply):
                if (200..<300).contains(reply.status) {
                    completedCount += 1
                    recent.append(Date())
                    return .completed(reply, model: reply.model ?? answer.model)
                }
                if reply.retryElsewhere {
                    // Declined here, or too long for this model: another
                    // host serving an accepted model may take it.
                    tried.insert(hostID)
                    let others = entries.values.contains { $0.model.map { choice.rank($0) != nil } ?? false
                        && !tried.contains($0.host.id) && ($0.capacity > 0 || !$0.active.isEmpty) }
                    if others && !(remaining().map { $0 <= 0 } ?? false) { continue }
                }
                rejectedCount += 1
                return .rejected(reply, model: reply.model ?? answer.model)
            case .failure(let error):
                if Task.isCancelled { return .cancelled }
                // Running out of the client's time isn't the host's fault.
                let outOfTime = remaining().map { $0 <= 0.5 } ?? false
                failures.record(error, outOfTime: outOfTime)
                if outOfTime {
                    return unavailable(retryAfter: estimateWait(choice), "the deadline passed while the request was running")
                }
                if case .busy = error, entries[hostID]?.report?.pulls == true {
                    // Another gateway took the slot first. The request waits
                    // here again, for this host to say it has one free, or
                    // for another host.
                    entries[hostID]?.full = true
                    continue
                }
                tried.insert(hostID)
                let message: String = switch error {
                case .unavailable(let why), .busy(let why): why
                case .failed(let status, let why): "runtime answered \(status): \(why)"
                case .cancelled: "the request was cancelled"
                }
                let others = entries.values.contains { $0.model.map { choice.rank($0) != nil } ?? false
                    && !tried.contains($0.host.id) && $0.capacity > 0 }
                if !others || (remaining().map { $0 <= 0 } ?? false) {
                    if case .busy = error {
                        busyCount += 1
                        return .busy(retryAfter: estimateWait(choice))
                    }
                    return unavailable(retryAfter: 5, message)
                }
            }
        }
    }

    /// Runs a request on the host holding `lease`, and keeps that host's
    /// record: its slot, its typical time, what it completed and failed.
    private func perform(_ body: Data, lease: Lease, host: any InferenceHost,
                         remaining: () -> TimeInterval?) async -> Result<HostReply, HostError> {
        let started = Date()
        let timeout = remaining() ?? config.maxExecution
        let result: Result<HostReply, HostError>
        if timeout <= 0 {
            result = .failure(.unavailable("no time left before the deadline"))
        } else {
            do {
                result = .success(try await host.complete(body, timeout: timeout,
                                                          options: RequestOptions(id: lease.id, prefetch: lease.mayWait)))
            } catch let error as HostError {
                result = .failure(Task.isCancelled ? .cancelled : error)
            } catch {
                result = .failure(Task.isCancelled || error is CancellationError
                                  ? .cancelled : .unavailable(error.localizedDescription))
            }
        }

        entries[lease.host]?.active[lease.id] = nil
        // A host on another device says how its slots stand with each answer.
        if entries[lease.host]?.report != nil { await read(lease.host) }
        switch result {
        case .success(let reply):
            let now = Date()
            entries[lease.host]?.record(seconds: now.timeIntervalSince(started))
            if (200..<300).contains(reply.status) {
                entries[lease.host]?.completed += 1
                entries[lease.host]?.recent.append(now)
                activity[lease.host, default: ActivityLog()].completed(Usage(reply.body), at: now)
                if let first = entries[lease.host]?.recent.first, first < now.addingTimeInterval(-600) {
                    entries[lease.host]?.recent.removeAll { $0 < now.addingTimeInterval(-600) }
                }
            }
        case .failure(.cancelled):
            break // A hedged copy that lost, or a client that left: not the host's doing.
        case .failure(let error):
            let outOfTime = remaining().map { $0 <= 0.5 } ?? false
            entries[lease.host]?.failures.record(error, outOfTime: outOfTime)
            if !outOfTime, error.isHostFault { activity[lease.host, default: ActivityLog()].failed() }
            if case .unavailable(let why) = error, !outOfTime {
                entries[lease.host]?.availability = .starting("not answering: \(why)")
            }
        }
        dispatch()
        return result
    }

    /// Runs a request from another device's gateway on one of this node's
    /// own hosts, now or not at all: no queue, since that gateway holds the
    /// queue and can try another host. Admission is this host's: a request
    /// gets a slot only if one is free, whoever's gateway it came from.
    ///
    /// A request sent ahead (`prefetch`) may instead wait here for the next
    /// free slot, ahead of anything else, if nothing else is waiting ahead
    /// and it would still finish in time.
    public func run(_ body: Data, onHost hostID: String, deadline: Date?, prefetch: Bool = false) async -> Outcome {
        func remaining() -> TimeInterval? { deadline.map { $0.timeIntervalSinceNow - config.margin } }
        guard let entry = entries[hostID], let model = entry.model else {
            return .unavailable(retryAfter: 30, message: "this device isn't serving a model")
        }
        let lease: Lease
        if entry.free > 0 {
            if let remaining = remaining(), remaining <= (entry.typical ?? 0) {
                return .busy(retryAfter: 1)
            }
            lease = reserve(hostID)
            account()
        } else {
            if entry.capacity == 0 {
                return .unavailable(retryAfter: 30, message: entry.state.detail ?? "this device isn't taking work")
            }
            guard prefetch, let held = await hold(hostID, deadline: deadline, remaining: remaining) else {
                if Task.isCancelled { return .cancelled }
                return .busy(retryAfter: estimateWait(ModelChoice(options: [.exact(model.id)])))
            }
            lease = held
        }
        guard let host = entries[hostID]?.host else {
            entries[hostID]?.active[lease.id] = nil
            return .unavailable(retryAfter: 30, message: "this device isn't serving a model")
        }
        switch await perform(body, lease: lease, host: host, remaining: remaining) {
        case .success(let reply):
            return (200..<300).contains(reply.status) ? .completed(reply, model: model)
                : .rejected(reply, model: model)
        case .failure(.busy):
            return .busy(retryAfter: 1)
        case .failure(.cancelled):
            return .cancelled
        case .failure(.unavailable(let why)):
            return .unavailable(retryAfter: 5, message: why)
        case .failure(.failed(let status, let why)):
            return .unavailable(retryAfter: 5, message: "runtime answered \(status): \(why)")
        }
    }

    private func unavailable(retryAfter: Int, _ message: String) -> Outcome {
        unavailableCount += 1
        return .unavailable(retryAfter: retryAfter, message: message)
    }

    /// A host with a free slot for this request, now or once one frees up,
    /// or nil if none does before `until`.
    private func acquire(choice: ModelChoice, excluding: Set<String>, until: Date,
                         remaining: @escaping () -> TimeInterval?) async -> Lease? {
        if let choice = pick(choice: choice, excluding: excluding, remaining: remaining()) {
            defer { account() }
            return reserve(choice)
        }
        return await enqueue(choice: choice, excluding: excluding, pinned: nil, until: until, remaining: remaining)
    }

    /// Holds a request a peer's gateway sent ahead until this host's next
    /// slot frees up, if it would still finish in time and no other request
    /// is held here. One at most, whichever gateway sent it: a host takes
    /// one request more than its slots, no more.
    private func hold(_ hostID: String, deadline: Date?, remaining: @escaping () -> TimeInterval?) async -> Lease? {
        guard let entry = entries[hostID], let typical = entry.typical,
              !waiting.contains(where: { $0.pinned == hostID }) else { return nil }
        let now = Date()
        let soonest = entry.active.values.map { max(0, typical - now.timeIntervalSince($0)) }.min() ?? 0
        let left = remaining() ?? config.defaultQueueWait
        guard soonest + typical < left else { return nil }
        entries[hostID]?.prefetched += 1
        return await enqueue(choice: ModelChoice(options: [.any]), excluding: [], pinned: hostID,
                             until: now.addingTimeInterval(left - typical), remaining: remaining)
    }

    private func enqueue(choice: ModelChoice, excluding: Set<String>, pinned: String?, until: Date,
                         remaining: @escaping () -> TimeInterval?) async -> Lease? {
        let wait = until.timeIntervalSinceNow
        guard wait > 0 else { return nil }
        let id = UUID()
        // Work waiting here means the tail of the batch is over: hedged
        // copies give their slots back.
        if pinned == nil { shedHedges() }
        // Isolated to this actor by name. The default overload is
        // nonisolated(nonsending), and optimized, it can return here off the
        // actor once `park` has waited: the request then runs on unguarded
        // state, and the next continuation's isolation check aborts the app.
        // SchedulerTests catch it only when built optimized.
        return await withTaskCancellationHandler(operation: {
            await park(id, choice: choice, excluding: excluding, pinned: pinned, for: wait, remaining: remaining)
        }, onCancel: {
            Task { await self.expire(id) }
        }, isolation: self)
    }

    private func park(_ id: UUID, choice: ModelChoice, excluding: Set<String>, pinned: String?,
                      for wait: TimeInterval, remaining: @escaping () -> TimeInterval?) async -> Lease? {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: nil)
                return
            }
            waiting.append(Waiter(id: id, choice: choice, excluded: excluding, pinned: pinned, remaining: remaining,
                                  continuation: continuation))
            account()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                await self?.expire(id)
            }
        }
    }

    private func reserve(_ choice: Pick) -> Lease { reserve(choice.id, prefetch: choice.prefetch, mayWait: choice.mayWait) }

    private func reserve(_ host: String, prefetch: Bool = false, mayWait: Bool = false) -> Lease {
        let lease = Lease(host: host, id: UUID(), prefetch: prefetch, mayWait: mayWait || prefetch)
        let now = Date()
        entries[host]?.active[lease.id] = now
        if prefetch {
            entries[host]?.prefetchedAt = now
            entries[host]?.prefetched += 1
        }
        return lease
    }

    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: nil)
        account()
    }

    /// Where to send a request.
    struct Pick {
        let id: String
        /// Sent ahead, to wait for a slot.
        var prefetch = false
        /// May wait for a slot if the free one is taken first.
        var mayWait = false
    }

    /// The most preferred host with a free slot whose typical time fits,
    /// and of those the quickest. A host not yet measured counts as
    /// quickest, so it gets a request and a typical time. Failing that, a fast host on another device to send the request
    /// ahead to, where it waits for that host's next free slot.
    ///
    /// Fast is judged against the quickest host the request could use, and
    /// a request may wait on a fast host only if it would still have time to
    /// wait behind a whole request, then run. A slow host is never sent
    /// work to wait.
    private func pick(choice: ModelChoice, excluding: Set<String>, remaining: TimeInterval?) -> Pick? {
        let quickest = config.prefetch ? entries.values.filter {
            $0.capacity > 0 && rank($0, for: choice, excluding: excluding, remaining: remaining) != nil
        }.compactMap(\.typical).min() : nil
        func fast(_ entry: Entry) -> Bool {
            guard let quickest, entry.report?.pulls == true, let typical = entry.typical,
                  typical <= config.prefetchUpTo, typical <= quickest * config.prefetchFactor else { return false }
            return remaining.map { $0 > 2 * typical } ?? true
        }

        let candidates = order.compactMap { id -> (entry: Entry, rank: Int)? in
            guard let entry = entries[id], entry.free > 0,
                  let rank = rank(entry, for: choice, excluding: excluding, remaining: remaining) else { return nil }
            return (entry, rank)
        }
        // Otherwise every tie goes to the host that joined first, slow or
        // not, while a quicker one sits idle.
        if let best = candidates.min(by: {
            ($0.rank, $0.entry.typical ?? 0, -$0.entry.free) < ($1.rank, $1.entry.typical ?? 0, -$1.entry.free)
        }) {
            return Pick(id: best.entry.host.id, mayWait: fast(best.entry))
        }

        let ahead = order.compactMap { id -> (id: String, rank: Int, typical: Double)? in
            guard let entry = entries[id], entry.canHold, fast(entry), let typical = entry.typical,
                  let rank = rank(entry, for: choice, excluding: excluding, remaining: remaining) else { return nil }
            return (id, rank, typical)
        }
        return ahead.min { ($0.rank, $0.typical) < ($1.rank, $1.typical) }.map { Pick(id: $0.id, prefetch: true) }
    }

    /// Whether a waiting request could run on this host, free slot or not.
    private func fits(_ waiter: Waiter, _ entry: Entry) -> Bool {
        if let pinned = waiter.pinned { return pinned == entry.host.id }
        return rank(entry, for: waiter.choice, excluding: waiter.excluded, remaining: waiter.remaining()) != nil
    }

    /// How far down a request's preferences this host is, if the request
    /// could run on it at all, free slot or not: its model is accepted, the
    /// request hasn't failed there, and its typical time fits.
    private func rank(_ entry: Entry, for choice: ModelChoice, excluding: Set<String>,
                      remaining: TimeInterval?) -> Int? {
        guard !excluding.contains(entry.host.id), let model = entry.model, let rank = choice.rank(model)
        else { return nil }
        if let remaining, remaining <= (entry.typical ?? 0) { return nil }
        return rank
    }

    /// Hands free slots to waiting requests: first those sent ahead by
    /// peers' gateways, which are already here, then the rest, oldest first.
    private func dispatch() {
        for ahead in [true, false] {
            var index = 0
            while index < waiting.count {
                let waiter = waiting[index]
                guard (waiter.pinned != nil) == ahead else {
                    index += 1
                    continue
                }
                let choice: Pick? = if let pinned = waiter.pinned {
                    (entries[pinned]?.free ?? 0) > 0 ? Pick(id: pinned) : nil
                } else {
                    pick(choice: waiter.choice, excluding: waiter.excluded, remaining: waiter.remaining())
                }
                if let choice {
                    waiting.remove(at: index)
                    // Reserved here, so the next waiter can't see the slot as free.
                    waiter.continuation.resume(returning: reserve(choice))
                } else {
                    index += 1
                }
            }
        }
        // A slot that nothing waits for may take a straggler's copy.
        if waiting.isEmpty {
            for id in attempts.keys { hedge(id) }
        }
        account()
    }

    // MARK: Hedging

    /// Runs a request on the host holding `lease`, and, if it runs well past
    /// that host's typical time while another host sits idle and nothing
    /// waits, a copy on that host too. Returns the first answer and cancels
    /// the other copy. Failures wait for the other copy, if one is running.
    private func attempt(_ body: Data, lease: Lease, model: ModelInfo, choice: ModelChoice, tried: Set<String>,
                         remaining: @escaping () -> TimeInterval?) async -> Answer {
        let id = UUID()
        // Copies run in tasks of their own, so cancelling the request's task
        // stops them here. Isolated to this actor by name, as in `enqueue`.
        return await withTaskCancellationHandler(operation: {
            await begin(body, lease: lease, model: model, choice: choice, tried: tried, remaining: remaining, as: id)
        }, onCancel: {
            Task { await self.abandon(id) }
        }, isolation: self)
    }

    private func begin(_ body: Data, lease: Lease, model: ModelInfo, choice: ModelChoice, tried: Set<String>,
                       remaining: @escaping () -> TimeInterval?, as id: UUID) async -> Answer {
        await withCheckedContinuation { continuation in
            attempts[id] = Attempt(body: body, choice: choice, tried: tried, remaining: remaining, first: lease.id,
                                   continuation: continuation)
            launch(lease, model: model, for: id)
            if Task.isCancelled {
                abandon(id)
            } else if config.hedge, let due = hedgeDue(lease) {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(due))
                    await self?.hedge(id)
                }
            }
        }
    }

    /// Stops every copy of a request whose client has gone. The request
    /// settles as cancelled once they have left their slots.
    private func abandon(_ id: UUID) {
        guard let attempt = attempts[id] else { return }
        attempts[id]?.hedged = true // So it gets no copy.
        for copy in attempt.copies.values { cancel(copy.lease) }
    }

    private func launch(_ lease: Lease, model: ModelInfo, for id: UUID) {
        guard let attempt = attempts[id], let host = entries[lease.host]?.host else { return }
        attempts[id]?.copies[lease.id] = (lease, model, Date())
        let body = attempt.body, remaining = attempt.remaining
        copies[lease.id] = Task {
            let result = await self.perform(body, lease: lease, host: host, remaining: remaining)
            self.settle(id, lease: lease, result: result)
        }
    }

    /// One copy is done. The first answer settles the request, and the other
    /// copy is cancelled. A failure settles it only if no other copy runs.
    private func settle(_ id: UUID, lease: Lease, result: Result<HostReply, HostError>) {
        copies[lease.id] = nil
        guard var attempt = attempts[id], let copy = attempt.copies.removeValue(forKey: lease.id) else { return }
        if case .failure(let error) = result, !attempt.copies.isEmpty {
            if error != .cancelled { attempt.failed.insert(lease.host) }
            attempts[id] = attempt
            return
        }
        attempts[id] = nil
        for other in attempt.copies.values { cancel(other.lease) }
        if case .success = result, lease.id != attempt.first { hedgeWinCount += 1 }
        attempt.continuation.resume(returning: Answer(host: lease.host, model: copy.model, result: result,
                                                      failed: attempt.failed))
    }

    /// Stops a copy. A host on another device is told, and answers the copy
    /// as cancelled once it has left its slot. A host this scheduler runs
    /// stops when the copy's task is cancelled.
    private func cancel(_ lease: Lease) {
        guard let entry = entries[lease.host], entry.report != nil else {
            copies[lease.id]?.cancel()
            return
        }
        let host = entry.host
        Task { await host.cancel(lease.id) }
    }

    /// Sends a copy of a straggling request to an idle host, if nothing waits
    /// and it hasn't been hedged already. The idle host is the quickest with a
    /// free slot that the request accepts and that would finish in time.
    private func hedge(_ id: UUID) {
        guard config.hedge, waiting.isEmpty, let attempt = attempts[id], !attempt.hedged,
              attempt.copies.count == 1, let running = attempt.copies.values.first,
              // Still in its slot: not one that has just answered.
              entries[running.lease.host]?.active[running.lease.id] != nil,
              let due = hedgeDue(running.lease), Date().timeIntervalSince(running.started) >= due else { return }
        let excluding = attempt.tried.union(attempt.failed).union([running.lease.host])
        let remaining = attempt.remaining()
        let idle = order.compactMap { host -> (id: String, model: ModelInfo, typical: Double)? in
            guard let entry = entries[host], entry.free > 0, let model = entry.model,
                  rank(entry, for: attempt.choice, excluding: excluding, remaining: remaining) != nil else { return nil }
            return (host, model, entry.typical ?? .infinity)
        }
        guard let target = idle.min(by: { $0.typical < $1.typical }) else { return }
        attempts[id]?.hedged = true
        hedgeCount += 1
        launch(reserve(target.id), model: target.model, for: id)
        account()
    }

    /// How long a copy runs before it counts as straggling: well past its
    /// host's typical time, plus one more for a copy sent ahead, which may
    /// first wait behind a whole request.
    private func hedgeDue(_ lease: Lease) -> TimeInterval? {
        guard let typical = entries[lease.host]?.typical else { return nil }
        return typical * config.hedgeAfter + (lease.prefetch ? typical : 0)
    }

    /// Cancels hedged copies still running alongside their first, so their
    /// slots go to work that's waiting.
    private func shedHedges() {
        for attempt in attempts.values where attempt.copies.count > 1 {
            for copy in attempt.copies.values where copy.lease.id != attempt.first {
                cancel(copy.lease)
            }
        }
    }

    /// Seconds until a slot is likely to free up for this choice.
    func estimateWait(_ choice: ModelChoice) -> Int {
        let hosts = entries.values.filter { $0.model.map { choice.rank($0) != nil } ?? false && $0.capacity > 0 }
        let capacity = hosts.reduce(0) { $0 + $1.capacity }
        guard capacity > 0 else { return 30 }
        let now = Date()
        var soonest = Double.infinity
        var typical = 0.0
        for host in hosts {
            guard let t = host.typical else { continue }
            typical = max(typical, t)
            for started in host.active.values {
                soonest = min(soonest, max(0, t - now.timeIntervalSince(started)))
            }
        }
        guard typical > 0 else { return 2 }
        if soonest == .infinity { soonest = 0 }
        let ahead = Double(waiting.filter { $0.pinned == nil && $0.choice == choice }.count) / Double(capacity)
        return min(60, max(1, Int((soonest + ahead * typical).rounded(.up))))
    }

    private func describe(_ choice: ModelChoice) -> String {
        let names = choice.options.map { option -> String in
            switch option {
            case .exact(let id): id
            case .any: "any"
            case .capability(let capability): "any-\(capability.rawValue)"
            }
        }
        return "no host serves \(names.joined(separator: ", "))"
    }

    private func pruneFinished() {
        let cutoff = Date().addingTimeInterval(-config.idempotencyTTL)
        finished = finished.filter { $0.value.at > cutoff }
        if finished.count > config.idempotencyCapacity {
            let keep = finished.sorted { $0.value.at > $1.value.at }.prefix(config.idempotencyCapacity)
            finished = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        recent.removeAll { $0 < Date().addingTimeInterval(-600) }
    }

    /// Keeps each host's idle-with-work time: how long it had a free slot
    /// while a request it could run waited here. Called whenever slots or
    /// the queue change.
    ///
    /// For a host whose slots this scheduler holds, that's exact. A host on
    /// another device may be free when this gateway thinks it's full, or
    /// busy with other gateways' work, so it counts its own free time and
    /// reports it (`note(_:for:)`).
    private func account() {
        let now = Date()
        for id in order {
            guard var entry = entries[id] else { continue }
            if let since = entry.freeSince { entry.freeTime += now.timeIntervalSince(since) }
            if let since = entry.waitedSince { entry.waitedTime += now.timeIntervalSince(since) }
            if let since = entry.idleSince {
                let idle = now.timeIntervalSince(since)
                entry.idleTime += idle
                idleWithWork += idle
            }
            let free = entry.free > 0
            let waited = waiting.contains { fits($0, entry) }
            entry.freeSince = free ? now : nil
            entry.waitedSince = waited ? now : nil
            entry.idleSince = free && waited && entry.report == nil ? now : nil
            entries[id] = entry

            // What a peer's gateway sees of this host, to tell it when it changes.
            let fingerprint = "\(entry.state)|\(entry.capacity)|\(entry.active.count)|\(held(id))|"
                + (entry.model?.fingerprint ?? "")
            if fingerprints[id] != fingerprint {
                fingerprints[id] = fingerprint
                generations[id, default: 0] += 1
                for (key, watcher) in watchers where watcher.host == id {
                    watchers.removeValue(forKey: key)
                    watcher.continuation.resume()
                }
            }
        }
    }

    private func held(_ id: String) -> Int { waiting.filter { $0.pinned == id }.count }

    /// One host's snapshot, and the count of its status changes. With
    /// `after`, waits up to `wait` seconds for a change past that count, so a
    /// peer's gateway hears of a free slot the moment there is one.
    func status(of hostID: String, after: Int?, wait: TimeInterval) async -> (host: HostSnapshot?, generation: Int) {
        account()
        if let after, generations[hostID, default: 0] <= after, wait > 0 {
            let id = UUID()
            await withCheckedContinuation { continuation in
                watchers[id] = (hostID, continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    await self?.stopWatching(id)
                }
            }
        }
        return (snapshot().hosts.first { $0.id == hostID }, generations[hostID, default: 0])
    }

    private func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.continuation.resume()
    }

    /// Takes a free-time count from a host on another device, and counts the
    /// part of it spent while work for that host waited here as idle with
    /// work. Between two reports, the share is the fraction of the time
    /// that work waited: exact when work waited throughout, as it does
    /// while a mesh is saturated.
    private func note(_ reported: (seconds: Double, at: Date), for id: String) {
        account()
        guard var entry = entries[id] else { return }
        if let last = entry.freeSample {
            guard reported.at > last.at else { return }
            let span = reported.at.timeIntervalSince(last.at)
            let free = reported.seconds - last.free
            if free > 0, span > 0 { // A count that went down is a host that restarted.
                let share = min(1, max(0, (entry.waitedTime - last.waited) / span))
                let idle = min(free, span) * share
                entry.idleTime += idle
                idleWithWork += idle
            }
        }
        entry.freeSample = (reported.seconds, entry.waitedTime, reported.at)
        entry.idleSince = nil
        entries[id] = entry
    }

    /// Each host's activity from `date` on, by host ID, including hosts
    /// that have left.
    public func activity(since date: Date) -> [String: [ActivityMinute]] {
        activity.mapValues { $0.since(date) }.filter { !$0.value.isEmpty }
    }

    public func snapshot() -> SchedulerSnapshot {
        account()
        let cutoff = Date().addingTimeInterval(-600)
        let hosts = order.compactMap { id -> HostSnapshot? in
            guard let e = entries[id] else { return nil }
            return HostSnapshot(id: id, model: e.model, state: e.state, slots: e.host.slots, capacity: e.capacity,
                                active: e.active.count, completed: e.completed, failures: e.failures,
                                typicalSeconds: e.typical,
                                perHour: Double(e.recent.filter { $0 > cutoff }.count) * 6,
                                idleWithWorkSeconds: e.idleTime, freeSeconds: e.freeTime,
                                held: e.report?.held ?? held(id), prefetched: e.prefetched,
                                hardware: e.host.hardware)
        }
        return SchedulerSnapshot(hosts: hosts, queued: waiting.count, completed: completedCount,
                                 failures: failures, rejected: rejectedCount, busy: busyCount,
                                 unavailable: unavailableCount, hedged: hedgeCount, hedgeWins: hedgeWinCount,
                                 perHour: Double(recent.filter { $0 > cutoff }.count) * 6,
                                 idleWithWorkSeconds: idleWithWork)
    }
}
