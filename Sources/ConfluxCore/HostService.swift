import Foundation

/// The protocol between a gateway and a host on another device: HTTP, carried
/// over iroh. Version 0, in the paths, until apple-iroh lets conflux name its
/// own ALPN (docs/plan.md, *apple-iroh changes*).
public enum HostProtocol {
    public static let version = 0
    public static let statusPath = "/conflux/0/host"
    public static let completePath = "/conflux/0/complete"
    /// Stops the completion named by `Conflux-Request-ID`, if it's still
    /// running or waiting: a hedged copy that lost.
    public static let cancelPath = "/conflux/0/cancel"
    /// Names one copy of a request, on a completion and on a cancel.
    public static let requestIDHeader = "Conflux-Request-ID"
    /// What became of a request sent to a host: `completed`, `rejected`
    /// (the runtime refused it, a 4xx to pass on), `unsuitable` (refused
    /// here, but another host might take it: declined content, or too long
    /// for this model), `busy`, `unavailable`, or `cancelled` by the gateway
    /// that sent it. Gateways that predate `unsuitable` pass it on as a 4xx.
    public static let outcomeHeader = "Conflux-Outcome"
    /// On a status request: the `generation` the gateway last saw. The host
    /// answers once its status has changed since, or after `Conflux-Wait`
    /// seconds, whichever is first.
    public static let afterHeader = "Conflux-After"
    public static let waitHeader = "Conflux-Wait"
    /// The longest a status request waits for a change.
    public static let longestWait: TimeInterval = 5
    /// On a completion: `1` if the request was sent ahead and may wait on the
    /// host for its next free slot.
    public static let prefetchHeader = "Conflux-Prefetch"
    /// On a completion's answer: how the host's slots stand once the request
    /// has left its slot, as `generation capacity active held`, so the
    /// gateway needn't wait for the status that says the same.
    public static let slotsHeader = "Conflux-Slots"
    /// The files of the model the host serves, listed (`PeerFileList`), and
    /// each by its role below it: `…/files/model`, `…/files/projector`.
    public static let filesPath = "/conflux/0/files"
}

/// What a host tells gateways about itself, polled every second.
struct HostStatus: Codable, Equatable {
    var `protocol`: Int
    var model: ModelInfo?
    /// `available`, `starting`, `paused`, `failed` or `offline`.
    var availability: String
    var detail: String?
    /// Slots it takes work in now, after its owner's intent and resource
    /// policy.
    var capacity: Int
    var active: Int
    var typicalSeconds: Double?
    /// Seconds the host has had a free slot since it started, counted by
    /// the host. A gateway can't see slots other gateways use, so it takes
    /// this to measure the time the host sat idle while its work waited.
    /// Optional: hosts before it was added don't send it.
    var freeSeconds: Double?
    /// Requests sent ahead, waiting for a slot. Nil from hosts before host
    /// pull.
    var held: Int?
    /// Counts the host's status changes, for `Conflux-After`. Nil from
    /// hosts before host pull, which answer at once.
    var generation: Int?
    /// What kind of device it is: chip, cores and memory, nothing that
    /// identifies it. Nil from hosts before it was added.
    var hardware: HardwareInfo?

    init(_ host: HostSnapshot?, generation: Int? = nil, hardware: HardwareInfo? = HardwareInfo.current) {
        self.protocol = HostProtocol.version
        model = host?.model
        capacity = host?.capacity ?? 0
        active = host?.active ?? 0
        typicalSeconds = host?.typicalSeconds
        freeSeconds = host?.freeSeconds
        held = host?.held ?? 0
        self.generation = generation
        self.hardware = hardware
        switch host?.state {
        case nil:
            (availability, detail) = ("offline", "this device isn't serving a model")
        case .ready, .busy, .draining:
            (availability, detail) = ("available", nil)
        case .paused(let why):
            (availability, detail) = ("paused", why)
        case .starting(let why):
            (availability, detail) = ("starting", why)
        case .failed(let why):
            (availability, detail) = ("failed", why)
        case .offline:
            (availability, detail) = ("offline", nil)
        }
    }

    var hostAvailability: HostAvailability {
        switch availability {
        case "available": .available
        case "starting": .starting(detail ?? "starting")
        case "paused": .paused(detail ?? "paused")
        case "failed": .failed(detail ?? "failed")
        default: .offline
        }
    }
}

/// Serves this device's own host to other devices' gateways. It listens on
/// loopback, where apple-iroh carries peers' streams to it, and accepts only
/// connections this process opened, so a program on this Mac can't use it to
/// get around the gateway's token.
final class HostService: Sendable {
    let scheduler: Scheduler
    /// This device's host, or nil when it serves no model and only uses
    /// peers'.
    let hostID: String?
    /// The files this device's host serves, by role: the only files it
    /// sends, whatever a request names.
    let files: [PeerFile.Role: String]
    /// Completions running or waiting, by request ID, so a gateway can cancel
    /// them, and IDs cancelled before their request arrived.
    private let running = Running()

    final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: Task<Outcome, Never>] = [:]
        private var early: [String: Date] = [:]

        /// Whether this request was cancelled before it arrived.
        func cancelledEarly(_ id: String) -> Bool {
            lock.withLock {
                early = early.filter { $0.value > Date().addingTimeInterval(-60) }
                return early.removeValue(forKey: id) != nil
            }
        }

        /// Registers a completion, unless it was cancelled in the meantime.
        func start(_ id: String, _ task: Task<Outcome, Never>) -> Bool {
            lock.withLock {
                if early.removeValue(forKey: id) != nil { return false }
                tasks[id] = task
                return true
            }
        }

        func finish(_ id: String) { lock.withLock { _ = tasks.removeValue(forKey: id) } }

        /// Whether a running completion was cancelled. Remembered for a
        /// minute either way, in case the request is still on its way.
        func cancel(_ id: String) -> Bool {
            lock.withLock {
                guard let task = tasks.removeValue(forKey: id) else {
                    early[id] = Date()
                    return false
                }
                task.cancel()
                return true
            }
        }
    }

    init(scheduler: Scheduler, hostID: String?, files: [PeerFile.Role: String] = [:]) {
        self.scheduler = scheduler
        self.hostID = hostID
        self.files = files
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", HostProtocol.statusPath):
            let after = request.header(HostProtocol.afterHeader).flatMap(Int.init)
            let wait = request.header(HostProtocol.waitHeader).flatMap(TimeInterval.init)
                .map { min(max(0, $0), HostProtocol.longestWait) } ?? 0
            var status = HostStatus(nil, generation: 0)
            if let hostID {
                let (host, generation) = await scheduler.status(of: hostID, after: after, wait: wait)
                status = HostStatus(host, generation: generation)
            } else if after != nil {
                // Nothing will change: don't have the gateway ask again at once.
                try? await Task.sleep(for: .seconds(wait))
            }
            let body = (try? HostService.encoder.encode(status)) ?? Data()
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
        case ("POST", HostProtocol.completePath):
            return await complete(request)
        case ("POST", HostProtocol.cancelPath):
            guard let id = request.header(HostProtocol.requestIDHeader) else {
                return Gateway.error(400, "name the request in \(HostProtocol.requestIDHeader)",
                                     type: "invalid_request_error")
            }
            return .json(200, ["cancelled": running.cancel(id)])
        case ("GET", HostProtocol.filesPath):
            return await listFiles()
        case ("GET", let path) where path.hasPrefix(HostProtocol.filesPath + "/"):
            return await serveFile(String(path.dropFirst(HostProtocol.filesPath.count + 1)), for: request)
        default:
            return Gateway.error(404, "no such endpoint: \(request.path)", type: "invalid_request_error")
        }
    }

    func complete(_ request: HTTPRequest) async -> HTTPResponse {
        let deadline = request.header(ContractHeader.timeout).flatMap(TimeInterval.init)
            .map { Date().addingTimeInterval($0) }
        guard let hostID else {
            return HTTPResponse(status: 503, headers: [("Content-Type", "application/json"),
                                                       (HostProtocol.outcomeHeader, "unavailable")],
                                body: ChatCompletionResult.error("this device serves no model", type: "server_error"))
        }
        let prefetch = request.header(HostProtocol.prefetchHeader) == "1"
        let id = request.header(HostProtocol.requestIDHeader)
        let outcome: Outcome
        if let id, running.cancelledEarly(id) {
            outcome = .cancelled
        } else {
            let scheduler = self.scheduler, body = request.body
            let task = Task { await scheduler.run(body, onHost: hostID, deadline: deadline, prefetch: prefetch) }
            if let id, !running.start(id, task) { task.cancel() }
            // The gateway that sent it closed the connection: it won't read
            // the answer, so the slot goes to other work.
            outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        if let id { running.finish(id) }
        let (host, generation) = await scheduler.status(of: hostID, after: nil, wait: 0)
        let slots = (HostProtocol.slotsHeader,
                     "\(generation) \(host?.capacity ?? 0) \(host?.active ?? 0) \(host?.held ?? 0)")
        func reply(_ status: Int, _ outcome: String, _ body: Data,
                   _ headers: [(name: String, value: String)] = []) -> HTTPResponse {
            HTTPResponse(status: status, headers: [("Content-Type", "application/json"),
                                                   (HostProtocol.outcomeHeader, outcome), slots] + headers, body: body)
        }
        switch outcome {
        case .completed(let result, let model):
            // Named here, by the host that ran it.
            return reply(result.status, "completed", Gateway.attribute(result.body, to: model))
        case .rejected(let result, let model):
            return reply(result.status, result.retryElsewhere ? "unsuitable" : "rejected",
                         Gateway.attribute(result.body, to: model))
        case .busy(let retryAfter):
            return reply(429, "busy", ChatCompletionResult.error("no free slot", type: "rate_limit_error"),
                         [(ContractHeader.retryAfter, String(retryAfter))])
        case .unavailable(let retryAfter, let message):
            return reply(503, "unavailable", ChatCompletionResult.error(message, type: "server_error"),
                         [(ContractHeader.retryAfter, String(retryAfter))])
        case .unknownModel(let message):
            return reply(503, "unavailable", ChatCompletionResult.error(message, type: "server_error"))
        case .cancelled:
            return reply(409, "cancelled", ChatCompletionResult.error("cancelled by the gateway that sent it",
                                                                      type: "server_error"))
        }
    }

    /// The files, each with its size and SHA-256. The host hashed them as
    /// it started, so this is a lookup in `FileHash`'s cache, or waits for
    /// that hashing to finish. A transfer holds no slot.
    func listFiles() async -> HTTPResponse {
        var listed: [PeerFile] = []
        for role in PeerFile.Role.allCases {
            guard let path = files[role] else { continue }
            do {
                listed.append(PeerFile(role: role, name: URL(fileURLWithPath: path).lastPathComponent,
                                       size: try Self.size(of: path), sha256: try await FileHash.sha256(of: path)))
            } catch {
                return Gateway.error(503, "can't read the model's files: \(error.localizedDescription)",
                                     type: "server_error")
            }
        }
        var list = PeerFileList(files: listed)
        if !listed.isEmpty, let hostID, let model = await scheduler.status(of: hostID, after: nil, wait: 0).0?.model {
            list.modelID = model.id
            // Provisional until the host has hashed its files.
            list.fingerprint = model.fingerprint == "identifying" ? nil : model.fingerprint
        }
        let body = (try? PeerFileList.encoder.encode(list)) ?? Data()
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
    }

    /// One of the files, by its role, with `Range` for resuming. A name that
    /// isn't one of the roles is refused: a path never comes from a request.
    func serveFile(_ name: String, for request: HTTPRequest) async -> HTTPResponse {
        guard let role = PeerFile.Role(rawValue: name), let path = files[role] else {
            return Gateway.error(404, "this device serves no such file", type: "invalid_request_error")
        }
        do {
            let size = try Self.size(of: path)
            let digest = try await FileHash.sha256(of: path)
            return .file(at: path, size: size, etag: digest, for: request)
        } catch {
            return Gateway.error(503, "can't read the model's files: \(error.localizedDescription)",
                                 type: "server_error")
        }
    }

    static func size(of path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
