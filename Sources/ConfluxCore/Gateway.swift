import Foundation
import Security

/// Header names from the client contract (docs/clients.md).
public enum ContractHeader {
    public static let timeout = "Conflux-Timeout"
    public static let models = "Conflux-Models"
    public static let idempotencyKey = "Idempotency-Key"
    public static let retryAfter = "Retry-After"
    /// On a response, the models that declined the request before the one
    /// the response names, in the order they did: `model-a, model-b`.
    public static let declined = "Conflux-Declined"
}

/// The OpenAI-compatible API clients talk to, on loopback.
public final class Gateway: Sendable {
    public let scheduler: Scheduler
    /// The owner's bearer token, or nil to allow requests without one.
    /// Tokenless access is an opt-in setting.
    public let token: String?
    /// Apps with tokens of their own, taken as well as the owner's while a
    /// token is required. Read at every request, so a revoked app is
    /// refused at its next.
    public let pairedApps: PairedApps?

    public init(scheduler: Scheduler, token: String?, pairedApps: PairedApps? = nil) {
        self.scheduler = scheduler
        self.token = token
        self.pairedApps = pairedApps
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"), ("HEAD", "/health"):
            // Anyone may ask whether the gateway is up. How much it's doing,
            // and for whom, is for clients with the token.
            guard authorized(request) else { return .json(200, ["status": "ok"]) }
            return .json(200, Gateway.health(await scheduler.snapshot()))
        case (_, "/health"):
            return methodNotAllowed("GET")
        case ("GET", "/v1/models"):
            guard authorized(request) else { return unauthorized() }
            return await models()
        case (_, "/v1/models"):
            return methodNotAllowed("GET")
        case ("POST", "/v1/chat/completions"):
            guard authorized(request) else { return unauthorized() }
            return await chat(request)
        case (_, "/v1/chat/completions"):
            return methodNotAllowed("POST")
        default:
            return Gateway.error(404, "no such endpoint: \(request.path)", type: "invalid_request_error",
                                 code: "unknown_url")
        }
    }

    // MARK: Endpoints

    func models() async -> HTTPResponse {
        let models = await scheduler.models()
        var data: [[String: Any]] = []
        let served = models.filter { $0.serving > 0 }.map(\.model)
        func list(_ option: ModelChoice.Option, _ description: String) {
            if served.contains(where: option.accepts) { data.append(Gateway.alias(option.name, description)) }
        }
        list(.any, "any model that's being served")
        list(.unfiltered(nil), "any model that filters no content")
        list(.capability(.vision), "any model that accepts images")
        list(.unfiltered(.vision), "any model that accepts images and filters no content")
        // A peer from before the variants were named serves it as a model.
        if !served.contains(where: { $0.id == AppleModelHost.alias }) {
            list(.exact(AppleModelHost.alias), "Apple's on-device model, whichever one a device runs")
        }
        // One for each tag a served model carries: the vocabulary's in its
        // order, then the owner's own.
        let tags = Set(served.flatMap(\.tags))
        for tag in ModelTag.vocabulary.map(\.id) where tags.contains(tag) {
            let promise = ModelTag.vocabulary.first { $0.id == tag }?.promise ?? ""
            list(.needs(ModelChoice.Needs(tags: [tag])), "any model trusted to " + promise.prefix(1).lowercased()
                 + promise.dropFirst())
        }
        for tag in tags.filter({ !ModelTag.isDocumented($0) }).sorted() {
            list(.needs(ModelChoice.Needs(tags: [tag])), "any model its owner tagged \(tag)")
        }
        for entry in models {
            var conflux: [String: Any] = [
                "capabilities": entry.model.capabilities.map(\.rawValue).sorted(),
                "content_filter": entry.model.contentFilter,
                "tags": entry.model.tags,
                "only_when_asked": entry.model.onlyWhenAsked,
                "fingerprint": entry.model.fingerprint,
                "hosts": entry.hosts,
                "serving": entry.serving,
            ]
            if let dimension = entry.model.maxImageDimension { conflux["max_image_dimension"] = dimension }
            if let tokens = entry.model.contextTokens { conflux["context_tokens"] = tokens }
            data.append(["id": entry.model.id, "object": "model", "created": 0, "owned_by": "conflux",
                         "conflux": conflux])
        }
        return .json(200, ["object": "list", "data": data])
    }

    /// `/health` for a client with the token: the mesh's and each host's
    /// counts, as the window shows them.
    static func health(_ snapshot: SchedulerSnapshot, now: Date = Date()) -> [String: Any] {
        func failures(_ counts: FailureCounts) -> [String: Any] {
            ["unavailable": counts.unavailable, "failed": counts.failed, "busy": counts.busy,
             "deadline": counts.deadline]
        }
        func seconds(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        func declined(_ counts: DeclineCounts) -> [String: Any] {
            ["content": counts.content, "length": counts.length, "unsupported": counts.unsupported,
             "seconds": seconds(counts.seconds)]
        }
        /// A fraction, 0 to 1, to three places.
        func fraction(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        func percentiles(_ value: Percentiles) -> [String: Any] {
            ["p50": seconds(value.p50), "p95": seconds(value.p95), "count": value.count]
        }
        let hosts = snapshot.hosts.map { host -> [String: Any] in
            var entry: [String: Any] = [
                "id": host.id, "state": host.state.label.lowercased(), "slots": host.slots,
                "capacity": host.capacity, "active": host.active, "completed": host.completed,
                "per_hour": host.perHour, "failures": failures(host.failures), "declined": declined(host.declined),
                "idle_with_work_seconds": seconds(host.idleWithWorkSeconds),
                "held": host.held, "prefetched": host.prefetched, "rejoined": host.rejoined,
            ]
            if let model = host.model { entry["model"] = model.id }
            if let detail = host.state.detail { entry["detail"] = detail }
            if let typical = host.typicalSeconds { entry["typical_seconds"] = seconds(typical) }
            if let pace = Gateway.pace(host.pace) { entry["pace"] = pace }
            if let request = host.requestSeconds { entry["request_seconds"] = percentiles(request) }
            if let utilization = host.utilization { entry["utilization"] = fraction(utilization) }
            if let hardware = host.hardware.map(Gateway.hardware), !hardware.isEmpty { entry["hardware"] = hardware }
            if let failure = host.lastFailure {
                entry["last_failure"] = ["reason": failure.reason,
                                         "at": failure.at.formatted(.iso8601),
                                         "seconds_ago": seconds(max(0, now.timeIntervalSince(failure.at)))]
            }
            return entry
        }
        var mesh: [String: Any] = [
            "queued": snapshot.queued, "completed": snapshot.completed, "per_hour": snapshot.perHour,
            "failures": failures(snapshot.failures),
            "declined": declined(snapshot.declined), "rerouted": snapshot.rerouted,
            "answered": ["rejected": snapshot.rejected, "busy": snapshot.busy,
                         "unavailable": snapshot.unavailable],
            "idle_with_work_seconds": seconds(snapshot.idleWithWorkSeconds),
            "hedged": snapshot.hedged, "hedge_wins": snapshot.hedgeWins,
        ]
        if let utilization = snapshot.utilization { mesh["utilization"] = fraction(utilization) }
        if let wait = snapshot.waitSeconds { mesh["wait_seconds"] = percentiles(wait) }
        return ["status": "ok", "mesh": mesh, "hosts": hosts]
    }

    /// How quickly a host reads and writes, for `/health`: only what's known,
    /// or nil when nothing is.
    static func pace(_ pace: HostPace) -> [String: Any]? {
        func rounded(_ value: Double, _ places: Double = 1000) -> Double { (value * places).rounded() / places }
        var entry: [String: Any] = [:]
        if let p = pace.secondsPerPromptToken { entry["seconds_per_1k_prompt_tokens"] = rounded(p * 1000) }
        if let w = pace.secondsPerWrittenToken { entry["seconds_per_1k_written_tokens"] = rounded(w * 1000) }
        if let i = pace.tokensPerImage { entry["tokens_per_image"] = i.rounded() }
        if let t = pace.templateTokens { entry["template_tokens"] = t.rounded() }
        if let w = pace.written { entry["written_tokens"] = w.rounded() }
        if let o = pace.overhead { entry["overhead_seconds"] = rounded(o) }
        return entry.isEmpty ? nil : entry
    }

    /// A host's hardware for `/health`: only the fields it reported.
    static func hardware(_ info: HardwareInfo) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let chip = info.chip { entry["chip"] = chip }
        if let cores = info.performanceCores { entry["performance_cores"] = cores }
        if let cores = info.efficiencyCores { entry["efficiency_cores"] = cores }
        if let cores = info.gpuCores { entry["gpu_cores"] = cores }
        if let bytes = info.memoryBytes { entry["memory_bytes"] = bytes }
        if let model = info.modelIdentifier { entry["model_identifier"] = model }
        return entry
    }

    static func alias(_ id: String, _ description: String) -> [String: Any] {
        ["id": id, "object": "model", "created": 0, "owned_by": "conflux",
         "conflux": ["alias": true, "description": description]]
    }

    func chat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Gateway.error(400, "the body must be a JSON object", type: "invalid_request_error")
        }
        if object["stream"] as? Bool == true {
            return Gateway.error(400, "streaming isn't supported yet; send \"stream\": false",
                                 type: "invalid_request_error", code: "stream_unsupported")
        }
        var deadline: Date?
        if let text = request.header(ContractHeader.timeout) {
            guard let seconds = TimeInterval(text), seconds > 0, seconds.isFinite else {
                return Gateway.error(400, "\(ContractHeader.timeout) must be a positive number of seconds",
                                     type: "invalid_request_error")
            }
            deadline = Date().addingTimeInterval(seconds)
        }
        let choice = ModelChoice(model: object["model"] as? String, preference: request.header(ContractHeader.models))
        let key = request.header(ContractHeader.idempotencyKey).flatMap { $0.isEmpty ? nil : $0 }

        switch await scheduler.submit(request.body, choice: choice, deadline: deadline, key: key) {
        case .completed(let reply, let model), .rejected(let reply, let model):
            return Gateway.answer(reply, from: model)
        case .busy(let retryAfter):
            return Gateway.error(429, "every slot is busy; try again shortly", type: "rate_limit_error",
                                 code: "busy", headers: [(ContractHeader.retryAfter, String(retryAfter))])
        case .unavailable(let retryAfter, let message):
            return Gateway.error(503, message, type: "server_error", code: "unavailable",
                                 headers: [(ContractHeader.retryAfter, String(retryAfter))])
        case .failed(let status, let message):
            // A host's answer, which a gateway's clients never get.
            return Gateway.error(503, "runtime answered \(status): \(message)", type: "server_error",
                                 code: "unavailable", headers: [(ContractHeader.retryAfter, "5")])
        case .unknownModel(let message):
            return Gateway.error(404, message, type: "invalid_request_error", code: "model_not_found")
        case .draining(let retryAfter):
            return Gateway.error(503, "this gateway is draining: it finishes what it has and takes nothing new",
                                 type: "server_error", code: "draining",
                                 headers: [(ContractHeader.retryAfter, String(retryAfter))])
        case .cancelled:
            // The client closed its connection, so it won't read this.
            return Gateway.error(503, "the request was cancelled", type: "server_error", code: "unavailable",
                                 headers: [(ContractHeader.retryAfter, "1")])
        }
    }

    /// A runtime's answer, passed on: attributed to the model that ran, and
    /// naming any that declined it first.
    static func answer(_ reply: HostReply, from model: ModelInfo) -> HTTPResponse {
        var headers = [("Content-Type", "application/json")]
        if !reply.declinedBy.isEmpty {
            headers.append((ContractHeader.declined, reply.declinedBy.joined(separator: ", ")))
        }
        return HTTPResponse(status: reply.status, headers: headers, body: Gateway.attribute(reply.body, to: model))
    }

    /// Sets `model` and `system_fingerprint` to what actually ran, whatever
    /// the runtime put there. Clients record these per response, a refusal
    /// included: there, beside `error`, they name the model that refused.
    static func attribute(_ body: Data, to model: ModelInfo) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        object["model"] = model.id
        object["system_fingerprint"] = model.fingerprint
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? body
    }

    // MARK: Authorization and errors

    func authorized(_ request: HTTPRequest) -> Bool {
        guard let token else { return true }
        guard let header = request.header("Authorization"), header.hasPrefix("Bearer ") else { return false }
        let sent = String(header.dropFirst("Bearer ".count))
        let owner = Gateway.constantTimeEqual(sent, token)
        let app = pairedApps?.app(withToken: sent) != nil
        return owner || app
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    func unauthorized() -> HTTPResponse {
        Gateway.error(401, "send the gateway's token as \"Authorization: Bearer <token>\"",
                      type: "invalid_request_error", code: "invalid_api_key",
                      headers: [("WWW-Authenticate", "Bearer")])
    }

    func methodNotAllowed(_ allowed: String) -> HTTPResponse {
        Gateway.error(405, "use \(allowed)", type: "invalid_request_error", headers: [("Allow", allowed)])
    }

    /// An error in the shape OpenAI clients expect.
    static func error(_ status: Int, _ message: String, type: String, code: String? = nil,
                      headers: [(name: String, value: String)] = []) -> HTTPResponse {
        var error: [String: Any] = ["message": message, "type": type]
        if let code { error["code"] = code }
        return .json(status, ["error": error], headers: headers)
    }
}

/// The gateway's bearer token, kept in a file only this user can read.
public enum TokenStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "conflux/token")
    }

    /// Reads the token, creating one the first time.
    public static func token(at url: URL = defaultURL) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        return try rotate(at: url)
    }

    /// Replaces the token with a new random one.
    @discardableResult
    public static func rotate(at url: URL = defaultURL) throws -> String {
        let token = try newToken()
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        manager.createFile(atPath: url.path, contents: Data((token + "\n").utf8),
                           attributes: [.posixPermissions: 0o600])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    /// A new random token, 256 bits, in the form every gateway token has.
    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        return "cfx_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
