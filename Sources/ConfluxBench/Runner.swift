import Foundation

/// One request, from first send to final answer, including any time spent
/// waiting out 429 or 503 responses.
public struct Record: Sendable, Codable, Equatable {
    public var index: Int
    /// Position in the corpus. Not the file name, which could say something
    /// personal.
    public var image: Int
    /// Seconds since the run started.
    public var start: Double
    public var end: Double
    public var status: Int?
    public var ok = false
    public var error: String?
    public var busyRetries = 0
    public var model: String?
    public var fingerprint: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var promptMs: Double?
    public var predictedMs: Double?

    public var latency: Double { end - start }
}

/// Hands out request numbers until the count or the time runs out.
actor Dispatcher {
    private var next = 0
    private let limit: Int?
    private let stopAt: Date?

    init(limit: Int?, stopAt: Date?) {
        self.limit = limit
        self.stopAt = stopAt
    }

    func take() -> Int? {
        if let limit, next >= limit { return nil }
        if let stopAt, Date() >= stopAt { return nil }
        defer { next += 1 }
        return next
    }
}

/// Keeps `concurrency` requests in flight against one endpoint, behaving the
/// way docs/clients.md asks a client to behave: a deadline header, a stable
/// idempotency key per request, and `Retry-After` honored on 429 and 503.
public struct Runner: Sendable {
    public let options: RunOptions
    public let corpus: [CorpusImage]
    public let session: URLSession
    public let progress: (@Sendable (Record) -> Void)?

    public init(options: RunOptions, corpus: [CorpusImage], session: URLSession? = nil,
                progress: (@Sendable (Record) -> Void)? = nil) {
        precondition(!corpus.isEmpty, "a run needs at least one image")
        self.options = options
        self.corpus = corpus
        self.session = session ?? Runner.session(for: options)
        self.progress = progress
    }

    /// URLSession allows six connections per host by default, which would
    /// quietly cap concurrency at six.
    public static func session(for options: RunOptions,
                               configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpMaximumConnectionsPerHost = options.concurrency + 2
        configuration.timeoutIntervalForRequest = options.timeout
        configuration.timeoutIntervalForResource = options.timeout * 4
        return URLSession(configuration: configuration)
    }

    public func run() async -> [Record] {
        let origin = Date()
        let dispatcher = Dispatcher(limit: options.effectiveRequests,
                                    stopAt: options.duration.map { origin.addingTimeInterval($0) })
        return await withTaskGroup(of: [Record].self) { group in
            for _ in 0..<options.concurrency {
                group.addTask {
                    var records: [Record] = []
                    while let index = await dispatcher.take() {
                        let record = await perform(index, origin: origin)
                        progress?(record)
                        records.append(record)
                    }
                    return records
                }
            }
            var all: [Record] = []
            for await records in group { all += records }
            return all.sorted { $0.index < $1.index }
        }
    }

    func perform(_ index: Int, origin: Date) async -> Record {
        let imageIndex = index % corpus.count
        let body = ChatRequest.body(prompt: options.prompt, jpeg: corpus[imageIndex].jpeg,
                                    model: options.model, maxTokens: options.maxTokens)
        // One key for every attempt at this request: retries are the same work.
        let request = ChatRequest.urlRequest(url: options.chatURL, body: body, token: options.token,
                                             timeout: options.timeout, idempotencyKey: UUID().uuidString)
        let started = Date()
        var record = Record(index: index, image: imageIndex, start: started.timeIntervalSince(origin), end: 0)

        func finish(_ error: String?) -> Record {
            record.end = Date().timeIntervalSince(origin)
            record.error = error
            record.ok = error == nil
            return record
        }

        while true {
            if Task.isCancelled { return finish("cancelled") }
            let data: Data
            let http: HTTPURLResponse?
            do {
                let (body, response) = try await session.data(for: request)
                data = body
                http = response as? HTTPURLResponse
            } catch {
                return finish(error.localizedDescription)
            }
            let status = http?.statusCode ?? 0
            record.status = status
            switch status {
            case 200..<300:
                do {
                    let result = try ChatResult.parse(data)
                    record.model = result.model
                    record.fingerprint = result.fingerprint
                    record.promptTokens = result.promptTokens
                    record.completionTokens = result.completionTokens
                    record.promptMs = result.promptMs
                    record.predictedMs = result.predictedMs
                    return finish(nil)
                } catch {
                    return finish("\(error)")
                }
            case 429, 503:
                record.busyRetries += 1
                if Date().timeIntervalSince(started) >= options.timeout {
                    return finish("busy for longer than the timeout")
                }
                let wait = min(30, RetryAfter.seconds(http?.value(forHTTPHeaderField: "Retry-After")) ?? 1)
                try? await Task.sleep(for: .seconds(wait))
            default:
                let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                return finish("HTTP \(status): \(snippet)")
            }
        }
    }
}
