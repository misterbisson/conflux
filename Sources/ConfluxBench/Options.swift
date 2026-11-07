import Foundation

public struct BenchError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What `conflux-bench run` was asked to do.
public struct RunOptions: Sendable, Equatable {
    /// The server's base URL, without `/v1/chat/completions`.
    public var endpoint: URL
    public var images: URL
    public var concurrency = 1
    /// Stop after this many requests. Mutually exclusive with `duration`.
    public var requests: Int?
    /// Stop sending new requests after this many seconds.
    public var duration: TimeInterval?
    /// Completions left out of the throughput figure while the server ramps up.
    /// Defaults to one per concurrent request.
    public var warmup: Int?
    public var prompt = "Describe this image in one paragraph."
    public var maxTokens = 256
    /// Images are downscaled so their longer side is at most this many pixels.
    public var maxDimension = 1024
    /// At most this many images are loaded from `images`. They're reused in turn.
    public var limit = 200
    public var model: String?
    public var token: String?
    public var timeout: TimeInterval = 120
    public var jsonPath: String?
    /// Where to write each request's answer, one JSON object per line.
    public var answersPath: String?
    public var label: String?

    public init(endpoint: URL, images: URL) {
        self.endpoint = endpoint
        self.images = images
    }

    public var chatURL: URL { endpoint.appending(path: "v1/chat/completions") }

    public var effectiveWarmup: Int { warmup ?? concurrency }

    /// With neither a count nor a duration, enough requests for a steady state.
    public var effectiveRequests: Int? {
        if requests == nil && duration == nil { return effectiveWarmup + max(20, 10 * concurrency) }
        return requests
    }

    /// Accepts `host:port`, a base URL, or a full `/v1/chat/completions` URL.
    public static func normalizeEndpoint(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        for suffix in ["/v1/chat/completions", "/v1"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil
        else { throw BenchError("not an http(s) endpoint: \(text)") }
        return url
    }

    public static func parse(_ args: [String], environment: [String: String] = [:]) throws -> RunOptions {
        var values: [String: String] = [:]
        var index = 0
        let known: Set<String> = [
            "--endpoint", "--images", "--concurrency", "--requests", "--duration", "--warmup",
            "--prompt", "--prompt-file", "--max-tokens", "--max-dimension", "--limit", "--model",
            "--timeout", "--json", "--save-answers", "--label",
        ]
        while index < args.count {
            let flag = args[index]
            guard known.contains(flag) else { throw BenchError("unknown option: \(flag)") }
            guard index + 1 < args.count else { throw BenchError("\(flag) needs a value") }
            values[flag] = args[index + 1]
            index += 2
        }

        guard let endpoint = values["--endpoint"] else { throw BenchError("--endpoint is required") }
        guard let images = values["--images"] else { throw BenchError("--images is required") }
        var options = RunOptions(endpoint: try normalizeEndpoint(endpoint),
                                 images: URL(fileURLWithPath: images))

        func int(_ flag: String, minimum: Int) throws -> Int? {
            guard let text = values[flag] else { return nil }
            guard let value = Int(text), value >= minimum else {
                throw BenchError("\(flag) must be a whole number of at least \(minimum)")
            }
            return value
        }
        func seconds(_ flag: String) throws -> TimeInterval? {
            guard let text = values[flag] else { return nil }
            guard let value = TimeInterval(text), value > 0 else {
                throw BenchError("\(flag) must be a positive number of seconds")
            }
            return value
        }

        options.concurrency = try int("--concurrency", minimum: 1) ?? options.concurrency
        options.requests = try int("--requests", minimum: 1)
        options.duration = try seconds("--duration")
        if options.requests != nil && options.duration != nil {
            throw BenchError("use --requests or --duration, not both")
        }
        options.warmup = try int("--warmup", minimum: 0)
        options.maxTokens = try int("--max-tokens", minimum: 1) ?? options.maxTokens
        options.maxDimension = try int("--max-dimension", minimum: 32) ?? options.maxDimension
        options.limit = try int("--limit", minimum: 1) ?? options.limit
        options.timeout = try seconds("--timeout") ?? options.timeout

        if values["--prompt"] != nil && values["--prompt-file"] != nil {
            throw BenchError("use --prompt or --prompt-file, not both")
        }
        if let prompt = values["--prompt"] { options.prompt = prompt }
        if let path = values["--prompt-file"] {
            options.prompt = try String(contentsOfFile: path, encoding: .utf8)
        }
        options.model = values["--model"]
        options.jsonPath = values["--json"]
        options.answersPath = values["--save-answers"]
        options.label = values["--label"]
        // From the environment only, so it stays out of shell history and process lists.
        options.token = environment["CONFLUX_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        return options
    }
}
