import Foundation

/// How a gateway reaches one peer's host service.
protocol PeerLink: Sendable {
    /// The peer's host service, dialling first if there's no connection.
    func url() async throws -> URL
    /// The connection looks lost: dial again when next asked.
    func reconnect()
    /// Why the last dial failed, if it did.
    var problem: String? { get async }
    /// Whether a connection is held and open now. Cheap: no dial.
    var connected: Bool { get async }
}

/// A host on another device, reached over iroh: what this Mac's gateway
/// schedules to when it sends work to a peer.
///
/// It keeps a status request open to the peer's host service, which answers
/// as soon as the host's slots change, and after a second if they don't.
/// So the gateway hears of a free slot within half a round trip, and the
/// requests are also the heartbeat: three misses in a row and the host counts
/// as not answering, and the link dials again. A peer from before host pull
/// answers at once, and is asked every second instead.
///
/// A peer can serve more than one host: a model file and Apple's model. The
/// first answers without naming it; the others are each a `RemoteHost` too,
/// naming theirs (`hostOnPeer`) in `Conflux-Host` (`PeerHosts`).
public final class RemoteHost: InferenceHost, @unchecked Sendable {
    public let id: String
    public let endpointID: String
    /// The host's ID on the peer, which it's asked for by name, or nil for
    /// the one the peer answers for by default.
    public let hostOnPeer: String?
    let link: any PeerLink
    private let session: URLSession
    private let lock = NSLock()
    private var status: HostStatus?
    private var statusAt = Date.distantPast
    private var misses = 0
    private var answering = false
    private var polling: Task<Void, Never>?
    private var changed: (@Sendable () -> Void)?
    /// The peer's other hosts, as its last status listed them, and who to
    /// tell when they change.
    private var others: [String] = []
    private var othersChanged: (@Sendable ([String]) -> Void)?
    static let missesBeforeLost = 3
    /// How long the peer may hold a status request before answering
    /// unchanged.
    static let statusWait: TimeInterval = 1

    init(endpointID: String, link: any PeerLink, hostOnPeer: String? = nil) {
        self.endpointID = endpointID
        self.hostOnPeer = hostOnPeer
        id = Self.id(endpointID, hostOnPeer)
        self.link = link
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: configuration)
    }

    deinit { polling?.cancel() }

    /// The scheduler's ID for a peer's host: `peer-<short ID>` for the one
    /// it answers for by default, and `peer-<short ID>-<host>` for another.
    public static func id(_ endpointID: String, _ hostOnPeer: String? = nil) -> String {
        "peer-\(DeviceIdentity.short(endpointID))" + (hostOnPeer.map { "-\($0)" } ?? "")
    }

    /// The host on the peer a scheduler ID names, from `id(_:_:)`: nil for
    /// the one it answers for by default, or an ID that isn't a peer's.
    public static func hostOnPeer(in id: String) -> String? {
        guard id.hasPrefix("peer-") else { return nil }
        let rest = id.dropFirst("peer-".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return String(rest[rest.index(after: dash)...])
    }

    /// Whether a status is this host's: a host named on a peer that doesn't
    /// say it's that host, a peer from before it could, isn't.
    private func mine(_ status: HostStatus) -> Bool {
        hostOnPeer == nil || status.host == hostOnPeer
    }

    public var model: ModelInfo? {
        get async { lock.withLock { answering && status.map(mine) == true ? status?.model : nil } }
    }

    /// The slots the peer takes work in now. Other gateways share them, and
    /// the peer refuses work it has no slot for.
    public var slots: Int {
        lock.withLock { status.map { mine($0) ? max(0, $0.capacity) : 0 } ?? 0 }
    }

    public var availability: HostAvailability {
        get async {
            let (status, answering, misses) = lock.withLock { (self.status, self.answering, self.misses) }
            if let status, answering {
                if status.protocol != HostProtocol.version {
                    return .failed("the peer runs conflux protocol \(status.protocol), and this Mac \(HostProtocol.version)")
                }
                guard mine(status) else { return .offline }
                return status.hostAvailability
            }
            if let problem = await link.problem { return .starting("can't reach the peer: \(problem)") }
            return .starting(misses > 0 ? "the peer isn't answering" : "connecting to the peer")
        }
    }

    public var report: HostReport? {
        get async {
            lock.withLock {
                guard answering, let status, mine(status) else { return nil }
                let held = status.held ?? 0
                return HostReport(free: max(0, status.capacity - status.active - held), held: held,
                                  freeSeconds: status.freeSeconds, pulls: status.generation != nil, at: statusAt)
            }
        }
    }

    /// What the peer last said about its hardware, kept while it's away:
    /// a device doesn't change kind.
    public var hardware: HardwareInfo? { lock.withLock { status?.hardware } }

    public func observe(_ changed: @escaping @Sendable () -> Void) {
        lock.withLock { self.changed = changed }
    }

    /// Calls `changed` with the peer's other hosts, by their IDs on the
    /// peer, each time its status lists a different set. Only the host the
    /// peer answers for by default hears of them.
    func observeOthers(_ changed: @escaping @Sendable ([String]) -> Void) {
        lock.withLock { othersChanged = changed }
    }

    /// The peer's other hosts, as its last status listed them.
    var otherHosts: [String] { lock.withLock { others } }

    /// Starts asking for the peer's status. `refresh` is called by it; tests
    /// call it directly. `interval` is for peers that answer at once.
    func start(every interval: Duration = .seconds(1)) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let held = await self.refresh(waitingUpTo: Self.statusWait)
                if !held { try? await Task.sleep(for: interval) }
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        lock.withLock { answering = false }
    }

    /// Asks for the peer's status. With `waitingUpTo`, a peer that does host
    /// pull holds the request until its status changes or that time passes.
    /// Returns whether it did, so the caller can ask again at once.
    @discardableResult
    func refresh(waitingUpTo wait: TimeInterval = 0) async -> Bool {
        defer {
            let changed = lock.withLock { self.changed }
            changed?()
        }
        // A closed connection is known at once, and redialling can take
        // seconds: say so before trying.
        if !(await link.connected) {
            lock.withLock {
                if answering { misses = Self.missesBeforeLost }
                answering = false
            }
        }
        let base: URL
        do {
            base = try await link.url()
        } catch {
            // No connection at all: lost now, not after three misses.
            lock.withLock {
                misses = max(misses + 1, Self.missesBeforeLost)
                answering = false
            }
            return false
        }
        let after = wait > 0 ? lock.withLock { answering ? status?.generation : nil } : nil
        do {
            var request = URLRequest(url: base.appending(path: HostProtocol.statusPath),
                                     timeoutInterval: 3 + (after == nil ? 0 : wait))
            request.httpMethod = "GET"
            if let after {
                request.setValue(String(after), forHTTPHeaderField: HostProtocol.afterHeader)
                request.setValue(String(wait), forHTTPHeaderField: HostProtocol.waitHeader)
            }
            if let hostOnPeer { request.setValue(hostOnPeer, forHTTPHeaderField: HostProtocol.hostHeader) }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let status = try HostService.decoder.decode(HostStatus.self, from: data)
            // A peer that doesn't say which host it answered for lists no
            // others: it predates them.
            let listed = hostOnPeer == nil
                ? status.host.map { me in (status.hosts ?? []).filter { $0 != me } } ?? [] : []
            let tell = lock.withLock { () -> (@Sendable ([String]) -> Void)? in
                self.status = status
                statusAt = Date()
                misses = 0
                answering = true
                guard listed != others else { return nil }
                others = listed
                return othersChanged
            }
            tell?(listed)
            return after != nil
        } catch {
            let lost = lock.withLock { () -> Bool in
                misses += 1
                if misses >= Self.missesBeforeLost { answering = false }
                return misses >= Self.missesBeforeLost
            }
            if lost { link.reconnect() }
            return false
        }
    }

    public func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
        try await complete(body, timeout: timeout, options: RequestOptions())
    }

    public func complete(_ body: Data, timeout: TimeInterval, options: RequestOptions) async throws -> HostReply {
        let base: URL
        do {
            base = try await link.url()
        } catch {
            throw HostError.unavailable("can't reach the peer: \(error)")
        }
        var request = URLRequest(url: base.appending(path: HostProtocol.completePath), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(format: "%.1f", timeout), forHTTPHeaderField: ContractHeader.timeout)
        if options.prefetch { request.setValue("1", forHTTPHeaderField: HostProtocol.prefetchHeader) }
        if let hostOnPeer { request.setValue(hostOnPeer, forHTTPHeaderField: HostProtocol.hostHeader) }
        request.setValue(options.id.uuidString, forHTTPHeaderField: HostProtocol.requestIDHeader)
        let data: Data, response: HTTPURLResponse
        do {
            let (bytes, answer) = try await session.data(for: request)
            guard let http = answer as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            (data, response) = (bytes, http)
        } catch {
            // Stopped here, not lost: the link is fine.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw HostError.cancelled }
            link.reconnect()
            throw HostError.unavailable("the peer didn't answer: \(error.localizedDescription)")
        }
        take(slots: response.value(forHTTPHeaderField: HostProtocol.slotsHeader))
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "status \(response.statusCode)"
        switch response.value(forHTTPHeaderField: HostProtocol.outcomeHeader) {
        case "completed":
            return HostReply(status: response.statusCode, body: data, model: ranModel(data))
        case "rejected":
            return HostReply(status: response.statusCode, body: data, model: ranModel(data))
        case "unsuitable":
            return HostReply(status: response.statusCode, body: data, model: ranModel(data), retryElsewhere: true)
        case "busy":
            throw HostError.busy("the peer has no free slot")
        case "cancelled":
            throw HostError.cancelled
        case "unavailable":
            throw HostError.unavailable(message)
        default:
            if response.statusCode >= 500 { throw HostError.failed(status: response.statusCode, message: message) }
            return HostReply(status: response.statusCode, body: data)
        }
    }

    /// Tells the peer to stop a request this gateway sent it. Its answer to
    /// the request itself then says `cancelled`.
    public func cancel(_ id: UUID) async {
        guard let base = try? await link.url() else { return }
        var request = URLRequest(url: base.appending(path: HostProtocol.cancelPath), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue(id.uuidString, forHTTPHeaderField: HostProtocol.requestIDHeader)
        if let hostOnPeer { request.setValue(hostOnPeer, forHTTPHeaderField: HostProtocol.hostHeader) }
        _ = try? await session.data(for: request)
    }

    /// How the peer's slots stand, from a completion's answer: newer than
    /// the last status if its generation is.
    func take(slots header: String?) {
        let numbers = header?.split(separator: " ").compactMap { Int($0) } ?? []
        guard numbers.count == 4 else { return }
        let updated = lock.withLock { () -> Bool in
            guard answering, var status, mine(status), let generation = status.generation, numbers[0] > generation
            else { return false }
            (status.generation, status.capacity, status.active, status.held) = (numbers[0], numbers[1], numbers[2], numbers[3])
            self.status = status
            statusAt = Date()
            return true
        }
        if updated { lock.withLock { changed }?() }
    }

    /// The model the peer says ran, or refused, from the answer itself.
    func ranModel(_ body: Data) -> ModelInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["model"] as? String, let fingerprint = object["system_fingerprint"] as? String
        else { return nil }
        let known = lock.withLock { status?.model }
        if let known, known.id == id, known.fingerprint == fingerprint { return known }
        return ModelInfo(id: id, capabilities: known?.id == id ? known?.capabilities ?? [] : [],
                         fingerprint: fingerprint)
    }
}
