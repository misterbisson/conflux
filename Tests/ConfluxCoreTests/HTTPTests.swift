import Foundation
import Testing
@testable import ConfluxCore

@Suite struct HTTPParserTests {
    func parse(_ text: String, max: Int = 1 << 20) -> HTTPParser.Result {
        HTTPParser.parse(Data(text.utf8), maxBodyBytes: max)
    }

    @Test func get() {
        let text = "GET /v1/models?x=1 HTTP/1.1\r\nHost: a\r\n\r\n"
        guard case .request(let request, let consumed) = parse(text) else { Issue.record("not parsed"); return }
        #expect(request.method == "GET")
        #expect(request.path == "/v1/models")
        #expect(request.header("host") == "a")
        #expect(request.keepAlive)
        #expect(consumed == text.utf8.count)
    }

    @Test func bodyArrivesInPieces() {
        let full = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        #expect(parse(String(full.prefix(20))) == .incomplete(expectsContinue: false))
        #expect(parse(String(full.dropLast(2))) == .incomplete(expectsContinue: false))
        guard case .request(let request, _) = parse(full) else { Issue.record("not parsed"); return }
        #expect(request.body == Data("hello".utf8))
    }

    @Test func pipelinedRequestsParseOneAtATime() {
        let two = "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n"
        guard case .request(let first, let consumed) = parse(two) else { Issue.record("not parsed"); return }
        #expect(first.path == "/a")
        guard case .request(let second, _) = parse(String(two.dropFirst(consumed))) else { Issue.record("second"); return }
        #expect(second.path == "/b")
    }

    @Test func chunkedBodies() {
        let text = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
        guard case .request(let request, let consumed) = parse(text) else { Issue.record("not parsed"); return }
        #expect(request.body == Data("hello world".utf8))
        #expect(consumed == text.utf8.count)
        #expect(parse(String(text.dropLast(4))) == .incomplete(expectsContinue: false))
    }

    @Test func expectContinue() {
        let text = "POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n"
        #expect(parse(text) == .incomplete(expectsContinue: true))
    }

    @Test func refusals() {
        if case .failure(413, _) = parse("POST /x HTTP/1.1\r\nContent-Length: 99\r\n\r\n", max: 10) {} else {
            Issue.record("expected 413")
        }
        if case .failure(400, _) = parse("NONSENSE\r\n\r\n") {} else { Issue.record("expected 400") }
        if case .failure(505, _) = parse("GET / HTTP/2.0\r\n\r\n") {} else { Issue.record("expected 505") }
        if case .failure(501, _) = parse("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n") {} else {
            Issue.record("expected 501")
        }
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes)
        if case .failure(431, _) = parse(huge) {} else { Issue.record("expected 431") }
    }

    @Test func connectionHandling() {
        #expect(!HTTPRequest(method: "GET", path: "/", headers: [("Connection", "close")]).keepAlive)
        #expect(!HTTPRequest(method: "GET", path: "/", version: "HTTP/1.0").keepAlive)
        #expect(HTTPRequest(method: "GET", path: "/", version: "HTTP/1.0", headers: [("Connection", "keep-alive")]).keepAlive)
    }

    @Test func responseBytes() {
        let response = HTTPResponse(status: 429, headers: [("Retry-After", "3"), ("Content-Length", "999")],
                                    body: Data("{}".utf8))
        let text = String(decoding: response.serialized(keepAlive: false), as: UTF8.self)
        #expect(text == "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    }
}

@Suite struct GatewayTests {
    func request(_ method: String = "POST", _ path: String = "/v1/chat/completions",
                 headers: [(name: String, value: String)] = [("Authorization", "Bearer t")],
                 body: String = #"{"messages":[]}"#) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    func json(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }

    @Test func authorization() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        #expect(await gateway.handle(request(headers: [])).status == 401)
        #expect(await gateway.handle(request(headers: [("Authorization", "Bearer wrong")])).status == 401)
        #expect(await gateway.handle(request()).status == 200)
        #expect(await gateway.handle(request("GET", "/health", headers: [])).status == 200)
        let open = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: nil)
        #expect(await open.handle(request(headers: [])).status == 200)
        #expect(Gateway.constantTimeEqual("abc", "abc"))
        #expect(!Gateway.constantTimeEqual("abc", "abcd"))
    }

    @Test func healthCountsForClientsWithTheToken() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        _ = await gateway.handle(request())
        let anonymous = json(await gateway.handle(request("GET", "/health", headers: [])))
        #expect(anonymous.keys.sorted() == ["status"])
        let health = json(await gateway.handle(request("GET", "/health")))
        let mesh = health["mesh"] as? [String: Any]
        #expect(mesh?["completed"] as? Int == 1)
        #expect(mesh?["idle_with_work_seconds"] as? Double == 0)
        #expect((mesh?["failures"] as? [String: Int])?["unavailable"] == 0)
        let host = (health["hosts"] as? [[String: Any]])?.first
        #expect(host?["id"] as? String == "h")
        #expect(host?["state"] as? String == "ready")
        #expect(host?["completed"] as? Int == 1)
        #expect(host?["model"] as? String == "model-a")
    }

    @Test func responsesNameWhatRan() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        let body = json(await gateway.handle(request()))
        #expect(body["model"] as? String == "model-a")
        #expect(body["system_fingerprint"] as? String == "fake-model-a")
    }

    @Test func refusalsNameTheModelThatRefused() async {
        let declined = ChatCompletionResult.error("declined", code: "content_filter")
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 0, status: 400, body: declined))
        let gateway = Gateway(scheduler: await Scheduler.with([host]), token: "t")
        let response = await gateway.handle(request())
        #expect(response.status == 400)
        let body = json(response)
        #expect((body["error"] as? [String: Any])?["code"] as? String == "content_filter")
        #expect(body["model"] as? String == "model-a")
        #expect(body["system_fingerprint"] as? String == "fake-model-a")
    }

    @Test func modelsListsAliasesFirst() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        let data = json(await gateway.handle(request("GET", "/v1/models"))) ["data"] as? [[String: Any]] ?? []
        #expect(data.map { $0["id"] as? String } == ["any", "any-vision", "model-a"])
        let conflux = data.last?["conflux"] as? [String: Any]
        #expect(conflux?["max_image_dimension"] as? Int == 1024)
        #expect(conflux?["capabilities"] as? [String] == ["text", "vision"])
    }

    @Test func busyCarriesRetryAfter() async {
        let host = FakeHost(id: "h", behavior: FakeHost.reply(after: 1))
        let gateway = Gateway(scheduler: await Scheduler.with([host]), token: "t")
        let first = Task { await gateway.handle(request()) }
        try? await Task.sleep(for: .milliseconds(50))
        let response = await gateway.handle(request(headers: [("Authorization", "Bearer t"), ("Conflux-Timeout", "0.5")]))
        #expect(response.status == 429)
        #expect(response.header("Retry-After") != nil)
        #expect((json(response)["error"] as? [String: Any])?["code"] as? String == "busy")
        _ = await first.value
    }

    @Test func refusals() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        #expect(await gateway.handle(request(body: "[1]")).status == 400)
        #expect(await gateway.handle(request(body: #"{"stream":true}"#)).status == 400)
        #expect(await gateway.handle(request(headers: [("Authorization", "Bearer t"), ("Conflux-Timeout", "soon")])).status == 400)
        #expect(await gateway.handle(request(body: #"{"model":"nope"}"#)).status == 404)
        #expect(await gateway.handle(request("GET")).status == 405)
        #expect(await gateway.handle(request("GET", "/v2/other")).status == 404)
    }

    @Test func preferenceHeaderOverridesModel() async {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "t")
        let response = await gateway.handle(request(headers: [("Authorization", "Bearer t"),
                                                              ("Conflux-Models", "nope, model-a")],
                                                    body: #"{"model":"nope"}"#))
        #expect(response.status == 200)
    }
}

@Suite struct ServerTests {
    @Test func servesOverLoopback() async throws {
        let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h", slots: 2)]), token: "t")
        let server = HTTPServer { await gateway.handle($0) }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        #expect(port > 0)

        let session = URLSession(configuration: .ephemeral)
        for _ in 0..<3 { // the same keep-alive connection, several times
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"messages":[]}"#.utf8)
            let (data, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["model"] as? String == "model-a")
        }
        let (_, health) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((health as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func largeBodies() async throws {
        let server = HTTPServer { request in HTTPResponse(status: 200, body: Data("\(request.body.count)".utf8)) }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo")!)
        request.httpMethod = "POST"
        request.httpBody = Data(count: 6_000_000)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect(String(decoding: data, as: UTF8.self) == "6000000")
    }

    /// A keep-alive connection holds only what it hasn't handled yet, however
    /// many requests it has carried. A buffer whose start has moved past the
    /// requests it handled is still holding their bytes.
    @Test func connectionsDontKeepWhatTheyHandled() {
        let request = Data("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        var buffer = Data()
        for _ in 0..<1000 {
            buffer.append(request)
            guard case .request(let parsed, let consumed) = HTTPParser.parse(buffer, maxBodyBytes: 1 << 20) else {
                Issue.record("not parsed")
                return
            }
            #expect(parsed.body == Data("hello".utf8))
            buffer = HTTPServer.remainder(of: buffer, after: consumed)
        }
        #expect(buffer.isEmpty)
        #expect(buffer.startIndex == 0)

        // What follows a request, the start of the next, is kept.
        let rest = HTTPServer.remainder(of: request + Data("GET".utf8), after: request.count)
        #expect(rest == Data("GET".utf8))
        #expect(rest.startIndex == 0)
        #expect(HTTPServer.remainder(of: request, after: request.count).isEmpty)
    }
}

@Suite struct SelfCheckTests {
    /// Cancelling the task that started a check, partway through, as
    /// memory relief's timer did to a model it was loading again, doesn't
    /// stop the check or fail a model that reads its input.
    @Test func runsToItsEndWhenItsCallerIsCancelled() async throws {
        let (asked, asking) = AsyncStream<Void>.makeStream()
        let caller = Task {
            await SelfCheck.run(vision: false) { body in
                asking.yield()
                try await Task.sleep(for: .milliseconds(50))
                let request = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let message = (request?["messages"] as? [[String: Any]])?.first
                let prompt = ((message?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let text = prompt.components(separatedBy: ": ").last ?? ""
                let answer = ["choices": [["message": ["role": "assistant", "content": text]]]]
                return HostReply(status: 200, body: try JSONSerialization.data(withJSONObject: answer))
            }
        }
        var probes = asked.makeAsyncIterator()
        _ = await probes.next()
        caller.cancel()
        #expect(await caller.value == nil)
    }

    @Test func matching() {
        #expect(SelfCheck.passes(answer: "The text says: k7-mp3.", expected: "K7MP3"))
        #expect(SelfCheck.passes(answer: "K 7 M P 3", expected: "K7MP3"))
        #expect(!SelfCheck.passes(answer: "A photograph of a sunset.", expected: "K7MP3"))
        #expect(!SelfCheck.passes(answer: "", expected: "K7MP3"))
        #expect(SelfCheck.passes(answer: "VCOM4", expected: "VCMV4") == false)
        #expect(SelfCheck.passes(answer: "VCMW4", expected: "VCMV4"))
        #expect(SelfCheck.passes(answer: "It reads VCMW4.", expected: "VCMV4"))
        #expect(!SelfCheck.passes(answer: "VCM", expected: "VCMV4"))
        #expect(!SelfCheck.passes(answer: "VCOM4", expected: "VCMV4", mistakes: 0))
        // A letter added or dropped, as small vision models do.
        #expect(SelfCheck.passes(answer: "TFEATL", expected: "TFETL"))
        #expect(SelfCheck.passes(answer: "It says LEERMP", expected: "LERMP"))
        #expect(SelfCheck.passes(answer: "3PW7", expected: "3PWW7"))
        #expect(!SelfCheck.passes(answer: "TFEAATL", expected: "TFETL"))
        #expect(!SelfCheck.passes(answer: "3P7", expected: "3PWW7"))
        // Two neighbours swapped, as the starter model did on an iPad.
        #expect(SelfCheck.passes(answer: " HMVRK", expected: "HMRVK"))
        #expect(SelfCheck.passes(answer: "MHRVK", expected: "HMRVK"))
        #expect(!SelfCheck.passes(answer: "MHRKV", expected: "HMRVK"))
        #expect(!SelfCheck.passes(answer: "HVRMK", expected: "HMRVK"))
        #expect(!SelfCheck.passes(answer: "HMVRK", expected: "HMRVK", mistakes: 0))
        #expect(SelfCheck.distance(Array("KITTEN"), Array("SITTING")) == 3)
        #expect(SelfCheck.distance(Array("HMVRK"), Array("HMRVK")) == 1)
        #expect(SelfCheck.distance(Array("CA"), Array("ABC")) == 3)
    }

    @Test func probes() throws {
        let vision = try SelfCheck.probe(vision: true)
        #expect(vision.expected.count == 5)
        let object = try JSONSerialization.jsonObject(with: vision.body) as? [String: Any]
        let content = ((object?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        let url = (content.last?["image_url"] as? [String: Any])?["url"] as? String
        #expect(url?.hasPrefix("data:image/jpeg;base64,") == true)
        let text = try SelfCheck.probe(vision: false)
        #expect(String(decoding: text.body, as: UTF8.self).contains(text.expected))
        #expect(SelfCheck.answer(in: Data(#"{"choices":[{"message":{"content":"X"}}]}"#.utf8)) == "X")
        #expect(SelfCheck.answer(in: Data("{}".utf8)) == nil)
    }

    @Test func probeTextNeverDoublesACharacter() {
        for _ in 0..<2000 {
            let text = SelfCheck.randomText()
            #expect(text.count == 5)
            #expect(zip(text, text.dropFirst()).allSatisfy { $0 != $1 }, "\(String(text))")
            #expect(text.allSatisfy(SelfCheck.alphabet.contains))
        }
    }
}
