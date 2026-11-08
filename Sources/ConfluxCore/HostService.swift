import Foundation

/// The protocol between a gateway and a host on another device: HTTP, carried
/// over iroh. Version 0, in the paths, until apple-iroh lets conflux name its
/// own ALPN (docs/plan.md, *apple-iroh changes*).
public enum HostProtocol {
    public static let version = 0
    public static let statusPath = "/conflux/0/host"
    public static let completePath = "/conflux/0/complete"
    /// What became of a request sent to a host: `completed`, `rejected`
    /// (the runtime refused it, a 4xx to pass on), `busy` or `unavailable`.
    public static let outcomeHeader = "Conflux-Outcome"
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

    init(_ host: HostSnapshot?) {
        self.protocol = HostProtocol.version
        model = host?.model
        capacity = host?.capacity ?? 0
        active = host?.active ?? 0
        typicalSeconds = host?.typicalSeconds
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

    init(scheduler: Scheduler, hostID: String?) {
        self.scheduler = scheduler
        self.hostID = hostID
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", HostProtocol.statusPath):
            let host = hostID == nil ? nil : await scheduler.snapshot().hosts.first { $0.id == hostID }
            let body = (try? HostService.encoder.encode(HostStatus(host))) ?? Data()
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
        case ("POST", HostProtocol.completePath):
            return await complete(request)
        default:
            return Gateway.error(404, "no such endpoint: \(request.path)", type: "invalid_request_error")
        }
    }

    func complete(_ request: HTTPRequest) async -> HTTPResponse {
        let deadline = request.header(ContractHeader.timeout).flatMap(TimeInterval.init)
            .map { Date().addingTimeInterval($0) }
        func reply(_ status: Int, _ outcome: String, _ body: Data,
                   _ headers: [(name: String, value: String)] = []) -> HTTPResponse {
            HTTPResponse(status: status, headers: [("Content-Type", "application/json"),
                                                   (HostProtocol.outcomeHeader, outcome)] + headers, body: body)
        }
        guard let hostID else {
            return reply(503, "unavailable", ChatCompletionResult.error("this device serves no model", type: "server_error"))
        }
        switch await scheduler.run(request.body, onHost: hostID, deadline: deadline) {
        case .completed(let result, let model):
            // Named here, by the host that ran it.
            return reply(result.status, "completed", Gateway.attribute(result.body, to: model))
        case .rejected(let result):
            return reply(result.status, "rejected", result.body)
        case .busy(let retryAfter):
            return reply(429, "busy", ChatCompletionResult.error("no free slot", type: "rate_limit_error"),
                         [(ContractHeader.retryAfter, String(retryAfter))])
        case .unavailable(let retryAfter, let message):
            return reply(503, "unavailable", ChatCompletionResult.error(message, type: "server_error"),
                         [(ContractHeader.retryAfter, String(retryAfter))])
        case .unknownModel(let message):
            return reply(503, "unavailable", ChatCompletionResult.error(message, type: "server_error"))
        }
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
