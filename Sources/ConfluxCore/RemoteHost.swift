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
/// It asks the peer's host service for its status every second, which is
/// also the heartbeat: three misses in a row and the host counts as not
/// answering, and the link dials again.
public final class RemoteHost: InferenceHost, @unchecked Sendable {
    public let id: String
    public let endpointID: String
    let link: any PeerLink
    private let session: URLSession
    private let lock = NSLock()
    private var status: HostStatus?
    private var statusAt = Date.distantPast
    private var misses = 0
    private var answering = false
    private var polling: Task<Void, Never>?
    static let missesBeforeLost = 3

    init(endpointID: String, link: any PeerLink) {
        self.endpointID = endpointID
        id = "peer-\(DeviceIdentity.short(endpointID))"
        self.link = link
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: configuration)
    }

    deinit { polling?.cancel() }

    public var model: ModelInfo? {
        get async { lock.withLock { answering ? status?.model : nil } }
    }

    /// The slots the peer takes work in now. Other gateways share them, and
    /// the peer refuses work it has no slot for.
    public var slots: Int { lock.withLock { max(0, status?.capacity ?? 0) } }

    public var availability: HostAvailability {
        get async {
            let (status, answering, misses) = lock.withLock { (self.status, self.answering, self.misses) }
            if let status, answering {
                if status.protocol != HostProtocol.version {
                    return .failed("the peer runs conflux protocol \(status.protocol), and this Mac \(HostProtocol.version)")
                }
                return status.hostAvailability
            }
            if let problem = await link.problem { return .starting("can't reach the peer: \(problem)") }
            return .starting(misses > 0 ? "the peer isn't answering" : "connecting to the peer")
        }
    }

    public var freeTime: (seconds: Double, at: Date)? {
        get async {
            lock.withLock { answering ? status?.freeSeconds.map { ($0, statusAt) } : nil }
        }
    }

    /// Starts the status poll. `refresh` is called by it; tests call it
    /// directly.
    func start(every interval: Duration = .seconds(1)) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        lock.withLock { answering = false }
    }

    func refresh() async {
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
            return
        }
        do {
            var request = URLRequest(url: base.appending(path: HostProtocol.statusPath), timeoutInterval: 3)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let status = try HostService.decoder.decode(HostStatus.self, from: data)
            lock.withLock {
                self.status = status
                statusAt = Date()
                misses = 0
                answering = true
            }
        } catch {
            let lost = lock.withLock { () -> Bool in
                misses += 1
                if misses >= Self.missesBeforeLost { answering = false }
                return misses >= Self.missesBeforeLost
            }
            if lost { link.reconnect() }
        }
    }

    public func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
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
        let data: Data, response: HTTPURLResponse
        do {
            let (bytes, answer) = try await session.data(for: request)
            guard let http = answer as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            (data, response) = (bytes, http)
        } catch {
            link.reconnect()
            throw HostError.unavailable("the peer didn't answer: \(error.localizedDescription)")
        }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "status \(response.statusCode)"
        switch response.value(forHTTPHeaderField: HostProtocol.outcomeHeader) {
        case "completed":
            return HostReply(status: response.statusCode, body: data, model: ranModel(data))
        case "rejected":
            return HostReply(status: response.statusCode, body: data)
        case "busy":
            throw HostError.busy("the peer has no free slot")
        case "unavailable":
            throw HostError.unavailable(message)
        default:
            if response.statusCode >= 500 { throw HostError.failed(status: response.statusCode, message: message) }
            return HostReply(status: response.statusCode, body: data)
        }
    }

    /// The model the peer says ran, from the answer itself.
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
