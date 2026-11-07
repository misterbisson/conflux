import Foundation
import Security

/// Header names from the client contract (docs/clients.md).
public enum ContractHeader {
    public static let timeout = "Conflux-Timeout"
    public static let models = "Conflux-Models"
    public static let idempotencyKey = "Idempotency-Key"
    public static let retryAfter = "Retry-After"
}

/// The OpenAI-compatible API clients talk to, on loopback.
public final class Gateway: Sendable {
    public let scheduler: Scheduler
    /// The bearer token clients must send, or nil to allow requests without
    /// one. Tokenless access is an opt-in setting.
    public let token: String?

    public init(scheduler: Scheduler, token: String?) {
        self.scheduler = scheduler
        self.token = token
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"), ("HEAD", "/health"):
            return .json(200, ["status": "ok"])
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
        if models.contains(where: { $0.serving > 0 }) {
            data.append(Gateway.alias("any", "any model that's being served"))
        }
        if models.contains(where: { $0.serving > 0 && $0.model.capabilities.contains(.vision) }) {
            data.append(Gateway.alias("any-vision", "any model that accepts images"))
        }
        for entry in models {
            var conflux: [String: Any] = [
                "capabilities": entry.model.capabilities.map(\.rawValue).sorted(),
                "fingerprint": entry.model.fingerprint,
                "hosts": entry.hosts,
                "serving": entry.serving,
            ]
            if let dimension = entry.model.maxImageDimension { conflux["max_image_dimension"] = dimension }
            data.append(["id": entry.model.id, "object": "model", "created": 0, "owned_by": "conflux",
                         "conflux": conflux])
        }
        return .json(200, ["object": "list", "data": data])
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
        case .completed(let reply, let model):
            return HTTPResponse(status: reply.status, headers: [("Content-Type", "application/json")],
                                body: Gateway.attribute(reply.body, to: model))
        case .rejected(let reply):
            return HTTPResponse(status: reply.status, headers: [("Content-Type", "application/json")],
                                body: reply.body)
        case .busy(let retryAfter):
            return Gateway.error(429, "every slot is busy; try again shortly", type: "rate_limit_error",
                                 code: "busy", headers: [(ContractHeader.retryAfter, String(retryAfter))])
        case .unavailable(let retryAfter, let message):
            return Gateway.error(503, message, type: "server_error", code: "unavailable",
                                 headers: [(ContractHeader.retryAfter, String(retryAfter))])
        case .unknownModel(let message):
            return Gateway.error(404, message, type: "invalid_request_error", code: "model_not_found")
        }
    }

    /// Sets `model` and `system_fingerprint` to what actually ran, whatever
    /// the runtime put there. Clients record these per response.
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
        return Gateway.constantTimeEqual(String(header.dropFirst("Bearer ".count)), token)
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
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = "cfx_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        manager.createFile(atPath: url.path, contents: Data((token + "\n").utf8),
                           attributes: [.posixPermissions: 0o600])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
