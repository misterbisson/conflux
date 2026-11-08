import Foundation

/// What became of one request.
public enum Outcome: Sendable, Equatable {
    /// The runtime answered successfully. `model` is what ran.
    case completed(HostReply, model: ModelInfo)
    /// The runtime refused the request itself (a 4xx). Passed on as is.
    case rejected(HostReply)
    /// No slot in time: 429.
    case busy(retryAfter: Int)
    /// Hosts failed and time ran out, or no host for an accepted model is up: 503.
    case unavailable(retryAfter: Int, message: String)
    /// No host has served a model this request accepts: 404.
    case unknownModel(String)
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

    public init(id: String, model: ModelInfo? = nil, state: HostState, slots: Int = 0, capacity: Int = 0,
                active: Int = 0, completed: Int = 0, failures: FailureCounts = FailureCounts(),
                typicalSeconds: Double? = nil, perHour: Double = 0, idleWithWorkSeconds: Double = 0,
                freeSeconds: Double = 0) {
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
        var reported: (free: Double, waited: TimeInterval, at: Date)?

        var capacity: Int {
            guard intent == .serving, availability == .available, model != nil else { return 0 }
            return min(host.slots, limit?.slots ?? host.slots)
        }
        var free: Int { max(0, capacity - active.count) }

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
    }

    struct Waiter {
        let id: UUID
        let choice: ModelChoice
        let excluded: Set<String>
        let remaining: () -> TimeInterval?
        let continuation: CheckedContinuation<Lease?, Never>
    }

    let config: SchedulerConfig
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var waiting: [Waiter] = []
    private var seen: [String: ModelInfo] = [:]
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var finished: [String: (outcome: Outcome, at: Date)] = [:]
    private var completedCount = 0, rejectedCount = 0, busyCount = 0, unavailableCount = 0
    private var failures = FailureCounts()
    private var recent: [Date] = []
    /// Every host's idle-with-work time, kept here too so it outlasts hosts
    /// that leave.
    private var idleWithWork: TimeInterval = 0
    private var refreshing: Task<Void, Never>?

    public init(config: SchedulerConfig = SchedulerConfig()) {
        self.config = config
    }

    // MARK: Hosts

    public func add(_ host: any InferenceHost) async {
        if entries[host.id] == nil { order.append(host.id) }
        entries[host.id] = Entry(host: host)
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

    /// Reads each host's model and availability. Runs every second once
    /// `startRefreshing` is called. Tests call it directly.
    public func refresh() async {
        for id in order {
            guard let host = entries[id]?.host else { continue }
            let model = await host.model
            let availability = await host.availability
            let reported = await host.freeTime
            entries[id]?.model = model
            entries[id]?.availability = availability
            if let model { seen[model.id] = model }
            if let reported { note(reported, for: id) }
        }
        dispatch()
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
    public func submit(_ body: Data, choice: ModelChoice, deadline: Date?, key: String?) async -> Outcome {
        pruneFinished()
        guard let key else { return await execute(body, choice: choice, deadline: deadline) }
        if let done = finished[key] { return done.outcome }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.execute(body, choice: choice, deadline: deadline) }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        switch outcome {
        case .completed, .rejected:
            finished[key] = (outcome, Date())
        default:
            break // Worth trying again: don't remember.
        }
        return outcome
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
            guard let lease = await acquire(choice: choice, excluding: tried, until: queueUntil, remaining: remaining)
            else {
                busyCount += 1
                return .busy(retryAfter: estimateWait(choice))
            }
            let hostID = lease.host
            guard let entry = entries[hostID], let model = entry.model else {
                entries[hostID]?.active[lease.id] = nil
                tried.insert(hostID)
                continue
            }
            switch await perform(body, lease: lease, host: entry.host, remaining: remaining) {
            case .success(let reply):
                if (200..<300).contains(reply.status) {
                    completedCount += 1
                    recent.append(Date())
                    return .completed(reply, model: reply.model ?? model)
                }
                rejectedCount += 1
                return .rejected(reply)
            case .failure(let error):
                // Running out of the client's time isn't the host's fault.
                let outOfTime = remaining().map { $0 <= 0.5 } ?? false
                failures.record(error, outOfTime: outOfTime)
                if outOfTime {
                    return unavailable(retryAfter: estimateWait(choice), "the deadline passed while the request was running")
                }
                tried.insert(hostID)
                let message: String = switch error {
                case .unavailable(let why), .busy(let why): why
                case .failed(let status, let why): "runtime answered \(status): \(why)"
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
                result = .success(try await host.complete(body, timeout: timeout))
            } catch let error as HostError {
                result = .failure(error)
            } catch {
                result = .failure(.unavailable(error.localizedDescription))
            }
        }

        entries[lease.host]?.active[lease.id] = nil
        switch result {
        case .success(let reply):
            let now = Date()
            entries[lease.host]?.record(seconds: now.timeIntervalSince(started))
            if (200..<300).contains(reply.status) {
                entries[lease.host]?.completed += 1
                entries[lease.host]?.recent.append(now)
                if let first = entries[lease.host]?.recent.first, first < now.addingTimeInterval(-600) {
                    entries[lease.host]?.recent.removeAll { $0 < now.addingTimeInterval(-600) }
                }
            }
        case .failure(let error):
            let outOfTime = remaining().map { $0 <= 0.5 } ?? false
            entries[lease.host]?.failures.record(error, outOfTime: outOfTime)
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
    public func run(_ body: Data, onHost hostID: String, deadline: Date?) async -> Outcome {
        func remaining() -> TimeInterval? { deadline.map { $0.timeIntervalSinceNow - config.margin } }
        guard let entry = entries[hostID], let model = entry.model else {
            return .unavailable(retryAfter: 30, message: "this device isn't serving a model")
        }
        guard entry.free > 0 else {
            if entry.capacity == 0 {
                return .unavailable(retryAfter: 30, message: entry.state.detail ?? "this device isn't taking work")
            }
            return .busy(retryAfter: estimateWait(ModelChoice(options: [.exact(model.id)])))
        }
        if let remaining = remaining(), remaining <= (entry.typical ?? 0) {
            return .busy(retryAfter: 1)
        }
        let lease = reserve(hostID)
        account()
        switch await perform(body, lease: lease, host: entry.host, remaining: remaining) {
        case .success(let reply):
            return (200..<300).contains(reply.status) ? .completed(reply, model: model) : .rejected(reply)
        case .failure(.busy):
            return .busy(retryAfter: 1)
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
        if let id = pick(choice: choice, excluding: excluding, remaining: remaining()) {
            defer { account() }
            return reserve(id)
        }
        let wait = until.timeIntervalSinceNow
        guard wait > 0 else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting.append(Waiter(id: id, choice: choice, excluded: excluding, remaining: remaining,
                                  continuation: continuation))
            account()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                await self?.expire(id)
            }
        }
    }

    private func reserve(_ host: String) -> Lease {
        let lease = Lease(host: host, id: UUID())
        entries[host]?.active[lease.id] = Date()
        return lease
    }

    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: nil)
        account()
    }

    /// The most preferred host with a free slot whose typical time fits.
    private func pick(choice: ModelChoice, excluding: Set<String>, remaining: TimeInterval?) -> String? {
        let candidates = order.compactMap { id -> (id: String, rank: Int, free: Int)? in
            guard let entry = entries[id], entry.free > 0,
                  let rank = rank(entry, for: choice, excluding: excluding, remaining: remaining) else { return nil }
            return (id, rank, entry.free)
        }
        return candidates.min { ($0.rank, -$0.free) < ($1.rank, -$1.free) }?.id
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

    /// Hands free slots to waiting requests, oldest first.
    private func dispatch() {
        var index = 0
        while index < waiting.count {
            let waiter = waiting[index]
            if let id = pick(choice: waiter.choice, excluding: waiter.excluded, remaining: waiter.remaining()) {
                waiting.remove(at: index)
                // Reserved here, so the next waiter can't see the slot as free.
                waiter.continuation.resume(returning: reserve(id))
            } else {
                index += 1
            }
        }
        account()
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
        let ahead = Double(waiting.filter { $0.choice == choice }.count) / Double(capacity)
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
            let waited = waiting.contains { rank(entry, for: $0.choice, excluding: $0.excluded,
                                                 remaining: $0.remaining()) != nil }
            entry.freeSince = free ? now : nil
            entry.waitedSince = waited ? now : nil
            entry.idleSince = free && waited && entry.reported == nil ? now : nil
            entries[id] = entry
        }
    }

    /// Takes a free-time count from a host on another device, and counts the
    /// part of it spent while work for that host waited here as idle with
    /// work. Between two reports, the share is the fraction of the time
    /// that work waited: exact when work waited throughout, as it does
    /// while a mesh is saturated.
    private func note(_ reported: (seconds: Double, at: Date), for id: String) {
        account()
        guard var entry = entries[id] else { return }
        if let last = entry.reported {
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
        entry.reported = (reported.seconds, entry.waitedTime, reported.at)
        entry.idleSince = nil
        entries[id] = entry
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
                                idleWithWorkSeconds: e.idleTime, freeSeconds: e.freeTime)
        }
        return SchedulerSnapshot(hosts: hosts, queued: waiting.count, completed: completedCount,
                                 failures: failures, rejected: rejectedCount, busy: busyCount,
                                 unavailable: unavailableCount,
                                 perHour: Double(recent.filter { $0 > cutoff }.count) * 6,
                                 idleWithWorkSeconds: idleWithWork)
    }
}
