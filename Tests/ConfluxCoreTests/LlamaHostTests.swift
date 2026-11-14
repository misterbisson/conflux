import Foundation
import Testing
@testable import ConfluxCore
import llama

@Suite struct ChatCompletionTests {
    func parse(_ json: String) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(Data(json.utf8), marker: "<m>")
    }

    static let pixel = "data:image/png;base64," + Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()

    @Test func messages() throws {
        let request = try parse(#"""
            {"messages":[{"role":"developer","content":"Be brief."},{"role":"user","content":"Hi"},
             {"role":"assistant","content":null}],
             "max_tokens":12,"temperature":0,"top_k":5,"seed":7,"stop":"END"}
            """#)
        #expect(request.messages == [.init(role: "system", text: "Be brief."), .init(role: "user", text: "Hi"),
                                     .init(role: "assistant", text: "")])
        #expect(request.maxTokens == 12)
        #expect(request.temperature == 0)
        #expect(request.topK == 5)
        #expect(request.topP == 0.95)
        #expect(request.seed == 7)
        #expect(request.stop == ["END"])
    }

    /// As llama.cpp joins them, so both runtimes see the same prompt: a
    /// newline between text parts, none next to an image.
    @Test func partsJoinLikeLlamaCpp() throws {
        let request = try parse("""
            {"messages":[{"role":"user","content":[
              {"type":"text","text":"Look."},{"type":"image_url","image_url":{"url":"\(Self.pixel)"}},
              {"type":"text","text":"What is it?"},{"type":"text","text":"Be brief."}]}],
             "max_completion_tokens":5,"stop":["a","","b"]}
            """)
        #expect(request.messages.first?.text == "Look.<m>What is it?\nBe brief.")
        #expect(request.images == [Data([0x89, 0x50, 0x4E, 0x47])])
        #expect(request.maxTokens == 5)
        #expect(request.stop == ["a", "b"])
    }

    @Test func refusals() {
        for body in [
            "[1]",
            #"{"messages":[]}"#,
            #"{"messages":[{"content":"no role"}]}"#,
            #"{"messages":[{"role":"user","content":5}]}"#,
            #"{"messages":[{"role":"user","content":[{"type":"input_audio"}]}]}"#,
            #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/a.jpg"}}]}]}"#,
            #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,"}}]}]}"#,
            #"{"messages":[{"role":"user","content":"x"}],"max_tokens":0}"#,
            #"{"messages":[{"role":"user","content":"x"}],"n":2}"#,
        ] {
            #expect(throws: ChatCompletionRequest.Invalid.self, "\(body)") { try parse(body) }
        }
    }

    @Test func stops() {
        #expect(ChatCompletionRequest.truncate("one two three", atFirstOf: ["three", "two"]) == "one ")
        #expect(ChatCompletionRequest.truncate("one", atFirstOf: ["x"]) == nil)
    }

    @Test func responseShape() throws {
        let result = ChatCompletionResult(text: "hi", finishReason: "length", promptTokens: 10, completionTokens: 4,
                                          promptMs: 500, predictedMs: 200)
        let object = try #require(try JSONSerialization.jsonObject(with: result.body(model: "m")) as? [String: Any])
        #expect(object["model"] as? String == "m")
        let choice = (object["choices"] as? [[String: Any]])?.first
        #expect((choice?["message"] as? [String: Any])?["content"] as? String == "hi")
        #expect(choice?["finish_reason"] as? String == "length")
        #expect((object["usage"] as? [String: Any])?["total_tokens"] as? Int == 14)
        let timings = object["timings"] as? [String: Any]
        #expect(timings?["prompt_ms"] as? Double == 500)
        #expect(timings?["predicted_per_second"] as? Double == 20)
        let error = try JSONSerialization.jsonObject(with: ChatCompletionResult.error("nope")) as? [String: Any]
        #expect((error?["error"] as? [String: Any])?["message"] as? String == "nope")
    }
}

@Suite struct LlamaRuntimeTests {
    @Test func savedSettingsFromEarlierVersionsLoad() throws {
        let old = #"{"model":"/m/a.gguf","slots":2,"contextPerSlot":8192,"maxImageDimension":768,"selfCheck":false,"extraArguments":[]}"#
        let config = try JSONDecoder().decode(ModelConfig.self, from: Data(old.utf8))
        #expect(config.runtime == .inProcess)
        #expect(config.slots == 2)
        #expect(config.imageMinTokens == nil)
        #expect(!config.selfCheck)
        let again = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }

    @Test func imageMinTokensReachLlamaServer() {
        let config = ModelConfig(runtime: .llamaServer, model: "/m/a.gguf", imageMinTokens: 1024)
        #expect(config.arguments(port: 1).contains("--image-min-tokens"))
    }

    @Test func warningsSinceAMark() {
        let log = LlamaLog()
        log.write(GGML_LOG_LEVEL_WARN, "old warning\n")
        let mark = log.mark()
        log.write(GGML_LOG_LEVEL_INFO, "info\n")
        log.write(GGML_LOG_LEVEL_WARN, "try adding --image-min-tokens 1024")
        log.write(GGML_LOG_LEVEL_CONT, "\n")
        #expect(log.warnings(since: mark) == "try adding --image-min-tokens 1024\n")
        #expect(SelfCheck.advice(in: log.warnings(since: mark)) == "add --image-min-tokens 1024")
    }

    @Test func threads() {
        #expect(LlamaRuntime.threads >= 1)
    }
}

private let testModelPath = ProcessInfo.processInfo.environment["CONFLUX_TEST_MODEL"]

/// Loads a real model. Set CONFLUX_TEST_MODEL to a GGUF file:
/// tools/ci/fetch-test-model.sh prints the path of a tiny one. Skipped
/// without it.
@Suite(.serialized, .enabled(if: testModelPath != nil))
struct LlamaHostIntegrationTests {

    func started(slots: Int = 1, context: Int = 256) async throws -> LlamaHost {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conflux-llama-\(UUID().uuidString)")
        let config = ModelConfig(model: try #require(testModelPath), slots: slots, contextPerSlot: context,
                                 selfCheck: false)
        let host = LlamaHost(config: config, logURL: directory.appending(path: "llama.log"))
        await host.start()
        let state = await host.availability
        #expect(state == (slots == 0 ? .paused(LlamaHost.noSlots) : .available), "\(state)")
        return host
    }

    /// A request that runs a while: this model writes into any JSON string
    /// it may until it runs out of tokens.
    func long(_ host: LlamaHost) -> Task<HostReply, any Error> {
        let body = #"{"messages":[{"role":"user","content":"Once upon a time"}],"temperature":0,"max_tokens":1900,"response_format":{"type":"json_object"}}"#
        return Task { try await host.complete(Data(body.utf8), timeout: 60) }
    }

    func ask(_ host: LlamaHost, _ extra: String = "") async throws -> (status: Int, object: [String: Any]) {
        let body = #"{"messages":[{"role":"user","content":"Once upon a time"}],"temperature":0"# + extra + "}"
        let reply = try await host.complete(Data(body.utf8), timeout: 60)
        return (reply.status, (try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]) ?? [:])
    }

    @Test func generates() async throws {
        let host = try await started()
        defer { host.stop() }
        let model = try #require(await host.model)
        #expect(model.fingerprint.hasPrefix("llama.cpp-b\(LlamaRuntime.build)-sha256:"))
        #expect(model.capabilities == [.text])

        let (status, object) = try await ask(host, #","max_tokens":8"#)
        #expect(status == 200)
        let choice = (object["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "length")
        let usage = object["usage"] as? [String: Any]
        #expect(usage?["completion_tokens"] as? Int == 8)
        #expect((usage?["prompt_tokens"] as? Int ?? 0) > 0)
        let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        #expect(!text.isEmpty)

        // Greedy decoding gives the same answer twice.
        let again = try await ask(host, #","max_tokens":8"#)
        let textAgain = ((again.object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        #expect(textAgain == text)

        // A stop string from the answer cuts it there.
        let word = String(text.split(separator: " ").last ?? "")
        if !word.isEmpty {
            let stopped = try await ask(host, #","max_tokens":8,"stop":["\#(word)"]"#)
            let content = ((stopped.object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            #expect(content.map { !$0.contains(word) } == true)
        }
    }

    @Test func refusals() async throws {
        let host = try await started()
        defer { host.stop() }
        let image = #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"\#(ChatCompletionTests.pixel)"}}]}]}"#
        #expect(try await host.complete(Data(image.utf8), timeout: 10).status == 400)
        let long = String(repeating: "word ", count: 400)
        let tooLong = #"{"messages":[{"role":"user","content":"\#(long)"}]}"#
        #expect(try await host.complete(Data(tooLong.utf8), timeout: 10).status == 400)
        #expect(try await host.complete(Data("{}".utf8), timeout: 10).status == 400)
    }

    /// llama.cpp accepts each grammar the converter makes, and the answer
    /// follows it. A schema it can't enforce goes to another host.
    @Test func answersInTheRequestedShape() async throws {
        let host = try await started()
        defer { host.stop() }
        let schemas = [
            #"{"type":"object","properties":{"mood":{"enum":["happy","sad"]},"count":{"type":"integer"}},"required":["mood","count"],"additionalProperties":false}"#,
            #"{"type":"array","items":{"type":"string","maxLength":6},"minItems":1,"maxItems":2}"#,
            #"{"type":"object","properties":{"a key \"q\"":{"type":["boolean","null"]},"é":{"const":{"x":[1,2.5]}}},"required":["é"]}"#,
            ##"{"$defs":{"leaf":{"type":"object","properties":{"kids":{"type":"array","items":{"$ref":"#/$defs/leaf"},"maxItems":1}},"required":["kids"]}},"$ref":"#/$defs/leaf"}"##,
            #"{"type":"array","prefixItems":[{"type":"number"},{"anyOf":[{"type":"null"},{"type":"string","maxLength":0}]}]}"#,
        ]
        for schema in schemas {
            let format = #","max_tokens":200,"response_format":{"type":"json_schema","json_schema":{"name":"t","schema":\#(schema)}}"#
            let (status, object) = try await ask(host, format)
            #expect(status == 200, "\(schema): \(object)")
            let choice = (object["choices"] as? [[String: Any]])?.first
            #expect(choice?["finish_reason"] as? String == "stop", "\(schema)")
            let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
            #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil,
                    "\(schema) gave \(text.debugDescription)")
        }
        // Open-ended: this model writes stories into any string it may, so
        // the answer runs out of tokens, but it starts as an object.
        for format in [#"{"type":"json_object"}"#,
                       #"{"type":"json_schema","json_schema":{"schema":{"additionalProperties":{"type":"integer"}}}}"#] {
            let (status, object) = try await ask(host, #","max_tokens":20,"response_format":\#(format)"#)
            let text = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            #expect(status == 200, "\(format): \(object)")
            #expect(text?.hasPrefix("{") == true, "\(format) gave \(text ?? "")")
        }

        let pattern = #","response_format":{"type":"json_schema","json_schema":{"schema":{"type":"string","pattern":"a+"}}}"#
        let body = #"{"messages":[{"role":"user","content":"Hi"}]"# + pattern + "}"
        let declined = try await host.complete(Data(body.utf8), timeout: 10)
        #expect(declined.status == 400 && declined.retryElsewhere)
    }

    @Test func slotsRunTogether() async throws {
        let host = try await started(slots: 2)
        async let first = ask(host, #","max_tokens":16"#)
        async let second = ask(host, #","max_tokens":16"#)
        let (a, b) = try await (first, second)
        #expect(a.status == 200 && b.status == 200)

        host.stop()
        #expect(await host.availability == .offline)
        await #expect(throws: HostError.self) { try await ask(host) }
    }

    @Test func slotsChangeWhileServing() async throws {
        let host = try await started(slots: 1)
        defer { host.stop() }
        await host.resize(to: 3, cancelling: false)
        #expect(host.slots == 3 && host.slotProblem == nil)
        async let a = ask(host, #","max_tokens":16"#)
        async let b = ask(host, #","max_tokens":16"#)
        async let c = ask(host, #","max_tokens":16"#)
        let replies = try await [a, b, c]
        #expect(replies.allSatisfy { $0.status == 200 })
        await host.resize(to: 1, cancelling: false)
        #expect(host.slots == 1)
        #expect(try await ask(host, #","max_tokens":8"#).status == 200)
    }

    /// Fewer slots than requests running: the request finishes in its slot,
    /// which then goes.
    @Test func aRemovedSlotFinishesItsRequest() async throws {
        let host = try await started(slots: 2, context: 2048)
        defer { host.stop() }
        let running = long(host)
        #expect(await eventually { host.running == 1 })
        await host.resize(to: 1, cancelling: false)
        await host.resize(to: 0, cancelling: false)
        #expect(host.slots == 0)
        #expect(await host.availability == .paused(LlamaHost.noSlots))
        #expect(try await running.value.status == 200)
        await #expect(throws: HostError.self) { try await ask(host) }
    }

    /// Or, asked to, it stops the request, which hears that its slot was
    /// taken away, so its gateway can send it elsewhere.
    @Test func aRemovedSlotCanStopItsRequest() async throws {
        let host = try await started(slots: 1, context: 2048)
        defer { host.stop() }
        let running = long(host)
        #expect(await eventually { host.running == 1 })
        await host.resize(to: 0, cancelling: true)
        await #expect(throws: HostError.busy("its slot was taken away while it ran")) { try await running.value }
    }

    /// A slot that goes while busy counts until its request ends, so the
    /// scheduler sees exactly the free ones. Stopping takes the newest
    /// request, which has done least.
    @Test func busySlotsRetireNewestFirst() async throws {
        let host = try await started(slots: 3, context: 2048)
        defer { host.stop() }
        let older = long(host)
        #expect(await eventually { host.running == 1 })
        let newer = long(host)
        #expect(await eventually { host.running == 2 })
        // The idle slot goes at once; one busy slot retires.
        await host.resize(to: 1, cancelling: false)
        #expect(host.slots == 2)
        await host.resize(to: 1, cancelling: true)
        await #expect(throws: HostError.busy("its slot was taken away while it ran")) { try await newer.value }
        #expect(try await older.value.status == 200)
        #expect(host.slots == 1)
        // Back up while nothing runs: a new slot is made.
        await host.resize(to: 2, cancelling: false)
        #expect(host.slots == 2)
    }

    /// No slots: the model is identified but not loaded. Slots load it.
    @Test func noSlotsThenSome() async throws {
        let host = try await started(slots: 0)
        defer { host.stop() }
        #expect(host.slots == 0)
        #expect(try #require(await host.model).fingerprint.hasPrefix("llama.cpp-b"))
        await #expect(throws: HostError.self) { try await ask(host) }
        await host.resize(to: 2, cancelling: false)
        #expect(await host.availability == .available)
        #expect(host.slots == 2)
        #expect(try await ask(host, #","max_tokens":8"#).status == 200)
    }

    /// Stopped, it stays stopped whatever its slots.
    @Test func stoppedStaysStopped() async throws {
        let host = try await started(slots: 1)
        host.stop()
        await host.resize(to: 0, cancelling: false)
        await host.resize(to: 2, cancelling: false)
        #expect(await host.availability == .offline)
    }

    @Test func missingFile() async {
        let host = LlamaHost(config: ModelConfig(model: "/nonexistent/model.gguf"),
                             logURL: FileManager.default.temporaryDirectory.appending(path: "conflux-missing.log"))
        await host.start()
        #expect(await host.availability == .failed("no file at /nonexistent/model.gguf"))
    }
}
