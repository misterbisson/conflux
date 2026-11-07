import Foundation
import Testing
@testable import ConfluxBench

/// Answers requests in-process, so the runner can be tested without a
/// server. Each test uses its own host name, so tests running in parallel
/// don't share responses.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    /// Replies are given in order. The last one repeats.
    static func script(host: String, _ replies: [Reply]) {
        lock.withLock { scripts[host] = replies; seen[host] = [] }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { seen[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let reply: Reply? = Self.lock.withLock {
            Self.seen[host, default: []].append(request)
            guard var replies = Self.scripts[host], let first = replies.first else { return nil }
            if replies.count > 1 { replies.removeFirst(); Self.scripts[host] = replies }
            return first
        }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct RunnerTests {
    static let ok = StubProtocol.Reply(status: 200, body: Data("""
        {"choices":[{"message":{"content":"fine"}}],"model":"stub-model","system_fingerprint":"fp",
         "usage":{"prompt_tokens":100,"completion_tokens":5}}
        """.utf8))

    func runner(host: String, concurrency: Int, requests: Int) throws -> Runner {
        var options = try RunOptions.parse(["--endpoint", "http://\(host):8080", "--images", "/unused",
                                            "--concurrency", String(concurrency), "--requests", String(requests),
                                            "--warmup", "0"])
        options.timeout = 10
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let corpus = [CorpusImage(name: "a", jpeg: Data([1]), width: 1, height: 1),
                      CorpusImage(name: "b", jpeg: Data([2]), width: 1, height: 1)]
        return Runner(options: options, corpus: corpus,
                      session: Runner.session(for: options, configuration: configuration))
    }

    @Test func completesEveryRequest() async throws {
        StubProtocol.script(host: "all-ok.test", [Self.ok])
        let records = try await runner(host: "all-ok.test", concurrency: 3, requests: 7).run()
        #expect(records.count == 7)
        #expect(records.map(\.index) == Array(0..<7))
        #expect(records.allSatisfy { $0.ok && $0.model == "stub-model" && $0.completionTokens == 5 })
        #expect(records.map(\.image) == [0, 1, 0, 1, 0, 1, 0])
        let sent = StubProtocol.requests(host: "all-ok.test")
        #expect(sent.count == 7)
        #expect(Set(sent.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }).count == 7)
    }

    @Test func waitsOutBusyResponsesWithTheSameKey() async throws {
        let busy = StubProtocol.Reply(status: 429, headers: ["Retry-After": "0"], body: Data())
        StubProtocol.script(host: "busy.test", [busy, busy, Self.ok])
        let records = try await runner(host: "busy.test", concurrency: 1, requests: 1).run()
        #expect(records.first?.ok == true)
        #expect(records.first?.busyRetries == 2)
        let keys = StubProtocol.requests(host: "busy.test").compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1)
    }

    @Test func retriesSendTheTimeLeft() async throws {
        let busy = StubProtocol.Reply(status: 429, headers: ["Retry-After": "1"], body: Data())
        StubProtocol.script(host: "deadline.test", [busy, Self.ok])
        let records = try await runner(host: "deadline.test", concurrency: 1, requests: 1).run()
        #expect(records.first?.ok == true)
        let deadlines = StubProtocol.requests(host: "deadline.test")
            .compactMap { $0.value(forHTTPHeaderField: "Conflux-Timeout").flatMap(Int.init) }
        #expect(deadlines.count == 2)
        #expect(deadlines.last! < deadlines.first!)
    }

    @Test func givesUpWhenTheWaitWouldPassTheTimeout() async throws {
        let busy = StubProtocol.Reply(status: 429, headers: ["Retry-After": "20"], body: Data())
        StubProtocol.script(host: "too-long.test", [busy, Self.ok])
        let records = try await runner(host: "too-long.test", concurrency: 1, requests: 1).run()
        #expect(records.first?.error == "busy for longer than the timeout")
        #expect(StubProtocol.requests(host: "too-long.test").count == 1)
    }

    @Test func recordsServerErrors() async throws {
        StubProtocol.script(host: "broken.test", [StubProtocol.Reply(status: 500, body: Data("boom".utf8))])
        let records = try await runner(host: "broken.test", concurrency: 2, requests: 2).run()
        #expect(records.allSatisfy { !$0.ok && $0.error == "HTTP 500: boom" && $0.status == 500 })
    }

    @Test func connectionsPerHostFollowConcurrency() throws {
        let options = try RunOptions.parse(["--endpoint", "127.0.0.1:1", "--images", "/x", "--concurrency", "12"])
        #expect(Runner.session(for: options).configuration.httpMaximumConnectionsPerHost == 14)
    }
}
