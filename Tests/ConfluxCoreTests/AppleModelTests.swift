import Foundation
import FoundationModels
import Testing
@testable import ConfluxCore

/// Apple's on-device model: turning a chat completion request into what it
/// takes, what its errors mean, and sending what it declines elsewhere. CI's
/// runners have no Apple Intelligence, so the model itself is tested only
/// where `CONFLUX_TEST_APPLE_MODEL` is set.
@Suite struct AppleModelRequestTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47])
    static var imageURL: String { "data:image/png;base64," + png.base64EncodedString() }

    func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func splitsInstructionsHistoryAndPrompt() throws {
        let request = try AppleModelRequest.parse(body([
            "messages": [
                ["role": "system", "content": "Be brief."],
                ["role": "developer", "content": "Answer in English."],
                ["role": "user", "content": [
                    ["type": "text", "text": "What is this?"],
                    ["type": "image_url", "image_url": ["url": Self.imageURL]],
                ]],
                ["role": "assistant", "content": "A test pattern."],
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": Self.imageURL]],
                    ["type": "text", "text": "And this?"],
                ]],
            ],
            "max_tokens": 50, "temperature": 0.2, "stop": "END",
        ]))
        #expect(request.instructions == "Be brief.\n\nAnswer in English.")
        #expect(request.history == [
            .init(role: .user, parts: [.text("What is this?"), .image(Self.png)]),
            .init(role: .assistant, parts: [.text("A test pattern.")]),
        ])
        #expect(request.prompt == [.image(Self.png), .text("And this?")])
        #expect(request.maxTokens == 50)
        #expect(request.temperature == 0.2)
        #expect(request.stop == ["END"])
        #expect(request.imageCount == 2)
    }

    @Test func leavesTheTemperatureToTheModel() throws {
        let request = try AppleModelRequest.parse(body(["messages": [["role": "user", "content": "Hi"]]]))
        #expect(request.temperature == nil)
        #expect(request.instructions == nil)
        #expect(request.prompt == [.text("Hi")])
    }

    @Test func refusesWhatNoHostWouldRun() {
        #expect(throws: AppleModelRequest.Failure.invalid("messages must be a non-empty array")) {
            try AppleModelRequest.parse(body(["messages": []]))
        }
        #expect(throws: AppleModelRequest.Failure.invalid("the last message must be the user's")) {
            try AppleModelRequest.parse(body(["messages": [["role": "user", "content": "Hi"],
                                                           ["role": "assistant", "content": "Hello"]]]))
        }
    }

    /// Another host may do what Apple's model doesn't.
    @Test func marksWhatAnotherHostMightRun() {
        let message = ["role": "user", "content": "Hi"]
        #expect(throws: AppleModelRequest.Failure.unsuited(
            "Apple's model here doesn't take a schema that allows any JSON object")) {
            try AppleModelRequest.parse(body(["messages": [message],
                                              "response_format": ["type": "json_schema", "json_schema": [:]]]))
        }
        #expect(throws: AppleModelRequest.Failure.unsuited("Apple's model here doesn't take tools")) {
            try AppleModelRequest.parse(body(["messages": [message], "tools": [["type": "function"]]]))
        }
        let text = try? AppleModelRequest.parse(body(["messages": [message], "response_format": ["type": "text"]]))
        #expect(text != nil && text?.schema == nil)
    }

    @Test func takesASchema() throws {
        let request = try AppleModelRequest.parse(Data(#"""
            {"messages":[{"role":"user","content":"Hi"}],
             "response_format":{"type":"json_schema","json_schema":{"name":"reading","strict":true,"schema":
               {"type":"object","properties":{"label":{"type":"string"},"count":{"type":"integer"}},
                "required":["label"]}}}}
            """#.utf8))
        #expect(request.schema == .object(name: "reading", properties: [
            .init(name: "label", schema: .string, optional: false),
            .init(name: "count", schema: .integer(minimum: nil, maximum: nil), optional: true),
        ]))
    }
}

/// `response_format` schemas, as Apple's guided generation takes them.
@Suite struct AppleModelSchemaTests {
    func schema(_ json: String, name: String? = nil) throws(AppleModelRequest.Failure) -> AppleModelSchema? {
        let named = name.map { #","name":"\#($0)""# } ?? ""
        let body = #"{"response_format":{"type":"json_schema","json_schema":{"schema":\#(json)\#(named)}}}"#
        return try AppleModelSchema.parse(Data(body.utf8))
    }

    func unsuited(_ json: String) -> Bool {
        do {
            _ = try schema(json)
            return false
        } catch {
            if case .unsuited = error { return true }
            return false
        }
    }

    /// The model writes properties in the schema's order, so it's kept.
    @Test func keepsThePropertiesInOrder() throws {
        let parsed = try schema(#"""
            {"type":"object","additionalProperties":false,"required":["zebra","apple","mood"],"properties":{
              "zebra":{"type":"string","description":"what it shows"},
              "apple":{"type":"integer","minimum":1,"maximum":5},
              "mood":{"type":"string","enum":["calm","busy"]},
              "tags":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3},
              "score":{"type":"number"},
              "done":{"type":"boolean"}}}
            """#, name: "Reading")
        #expect(parsed == .object(name: "Reading", properties: [
            .init(name: "zebra", description: "what it shows", schema: .string, optional: false),
            .init(name: "apple", schema: .integer(minimum: 1, maximum: 5), optional: false),
            .init(name: "mood", schema: .strings(name: "Reading.mood", ["calm", "busy"]), optional: false),
            .init(name: "tags", schema: .array(.string, minimum: 1, maximum: 3), optional: true),
            .init(name: "score", schema: .number, optional: true),
            .init(name: "done", schema: .boolean, optional: true),
        ]))
    }

    @Test func choicesConstantsAndNull() throws {
        let parsed = try schema(#"""
            {"type":"object","required":["kind","note","size","level"],"properties":{
              "kind":{"const":"photo"},
              "note":{"type":["string","null"]},
              "size":{"anyOf":[{"type":"integer"},{"enum":["small","large"]}]},
              "level":{"enum":[1,"high",null]}}}
            """#)
        #expect(parsed == .object(name: "Answer", properties: [
            .init(name: "kind", schema: .constant("photo"), optional: false),
            .init(name: "note", schema: .choice(name: "Answer.note", [.string, .null]), optional: false),
            .init(name: "size", schema: .choice(name: "Answer.size", [
                .integer(minimum: nil, maximum: nil), .strings(name: "Answer.size.2", ["small", "large"]),
            ]), optional: false),
            .init(name: "level", schema: .choice(name: "Answer.level", [
                .integer(minimum: 1, maximum: 1), .constant("high"), .null,
            ]), optional: false),
        ]))
    }

    /// Each use of a reference gets a name of its own: Apple's model needs
    /// every name to be unique.
    @Test func referencesAreExpandedWhereUsed() throws {
        let parsed = try schema(#"""
            {"type":"object","required":["a","b"],"$defs":{"Item":{"type":"object","required":["n"],
              "properties":{"n":{"type":"string"}}}},
             "properties":{"a":{"$ref":"#/$defs/Item"},"b":{"$ref":"#/$defs/Item"}}}
            """#)
        let item = { (name: String) in
            AppleModelSchema.object(name: name, properties: [.init(name: "n", schema: .string, optional: false)])
        }
        #expect(parsed == .object(name: "Answer", properties: [
            .init(name: "a", schema: item("Answer.a"), optional: false),
            .init(name: "b", schema: item("Answer.b"), optional: false),
        ]))
    }

    @Test func textAsksForNoSchema() throws {
        #expect(try AppleModelSchema.parse(Data(#"{"messages":[]}"#.utf8)) == nil)
        #expect(try AppleModelSchema.parse(Data(#"{"response_format":{"type":"text"}}"#.utf8)) == nil)
    }

    /// What a llama.cpp host enforces and Apple's model can't goes there.
    @Test func leavesToAnotherHostWhatItCantEnforce() {
        #expect(unsuited(#"{"type":"object","properties":{"d":{"type":"string","pattern":"^[0-9]+$"}}}"#))
        #expect(unsuited(#"{"type":"object","properties":{"d":{"type":"string","format":"date"}}}"#))
        #expect(unsuited(#"{"type":"object","properties":{"d":{"type":"string","maxLength":10}}}"#))
        #expect(unsuited(#"{"type":"object","properties":{"d":{"allOf":[{"type":"string"}]}}}"#))
        #expect(unsuited(#"{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}]}"#))
        #expect(unsuited(#"{"type":"object"}"#))
        #expect(unsuited(#"{"type":"object","additionalProperties":{"type":"string"}}"#))
        #expect(unsuited(#"{"type":"object","properties":{"d":{}}}"#))
        #expect(unsuited(#"{"type":"object","properties":{"d":{"const":true}}}"#))
        #expect(unsuited(##"{"$defs":{"N":{"type":"object","properties":{"next":{"$ref":"#/$defs/N"}}}},"$ref":"#/$defs/N"}"##))
        #expect(throws: AppleModelRequest.Failure.unsuited(
            "Apple's model here doesn't take a schema that allows any JSON object")) {
            try AppleModelSchema.parse(Data(#"{"response_format":{"type":"json_object"}}"#.utf8))
        }
    }

    /// Malformed for one host is malformed for every host.
    @Test func refusesAMalformedSchema() {
        #expect(throws: AppleModelRequest.Failure.invalid("JSON schema error at #/properties/d: unrecognized type text")) {
            try schema(#"{"type":"object","properties":{"d":{"type":"text"}}}"#)
        }
        #expect(throws: AppleModelRequest.Failure.self) {
            try AppleModelSchema.parse(Data(#"{"response_format":{"type":"yaml"}}"#.utf8))
        }
    }

    /// Building the framework's schema needs no Apple Intelligence, so CI
    /// checks that what this writes is a schema the framework accepts.
    @Test func theFrameworkAcceptsTheSchema() throws {
        let parsed = try #require(try schema(#"""
            {"type":"object","required":["kind","mood","items"],"$defs":{"Item":{"type":"object",
              "properties":{"n":{"type":["string","null"]}}}},
             "properties":{"kind":{"const":"photo"},"mood":{"enum":["calm","busy"]},
              "items":{"type":"array","items":{"$ref":"#/$defs/Item"},"maxItems":2},
              "more":{"type":"array","items":{"$ref":"#/$defs/Item"}},
              "count":{"type":"integer","minimum":0}}}
            """#, name: "Reading"))
        let generation = try GenerationSchema(root: AppleModelHost.dynamic(parsed), dependencies: [])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(generation)) as? [String: Any]
        #expect(encoded?["title"] as? String == "Reading")
        #expect(encoded?["x-order"] as? [String] == ["kind", "mood", "items", "more", "count"])
        #expect(encoded?["required"] as? [String] == ["kind", "mood", "items"])
    }

    /// The answer keeps the order the model wrote it in.
    @Test func writesTheAnswerInOrder() {
        let content = GeneratedContent(kind: .structure(properties: [
            "zebra": GeneratedContent(kind: .string("a \"quoted\" word")),
            "apple": GeneratedContent(kind: .number(3)),
            "score": GeneratedContent(kind: .number(0.25)),
            "tags": GeneratedContent(kind: .array([GeneratedContent(kind: .bool(true)), GeneratedContent(kind: .null)])),
        ], orderedKeys: ["zebra", "apple", "score", "tags"]))
        #expect(AppleModelHost.json(content)
            == #"{"zebra":"a \"quoted\" word","apple":3,"score":0.25,"tags":[true,null]}"#)
    }
}

@Suite struct AppleModelHostTests {
    func declined(_ result: Result<HostReply, HostError>, code: String) -> Bool {
        guard case .success(let reply) = result, reply.status == 400, reply.retryElsewhere,
              let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
        else { return false }
        return (object["error"] as? [String: Any])?["code"] as? String == code
    }

    @Test func errorsThatAnotherHostMightNotGive() {
        let tooLong = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000,
                                                                    debugDescription: "too long"))
        #expect(declined(AppleModelHost.outcome(for: tooLong), code: "context_length_exceeded"))
        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "no"))
        #expect(declined(AppleModelHost.outcome(for: guardrail), code: "content_filter"))
        let refusal = LanguageModelError.refusal(.init(explanation: "no", debugDescription: "no"))
        #expect(declined(AppleModelHost.outcome(for: refusal), code: "content_filter"))
    }

    @Test func errorsThatAreTheHosts() {
        let limited = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "slow down"))
        #expect(AppleModelHost.outcome(for: limited) == .failure(.busy("Apple's model is rate limited")))
        #expect(AppleModelHost.outcome(for: CancellationError()) == .failure(.cancelled))
        struct Odd: Error {}
        guard case .failure(.failed(status: 500, _)) = AppleModelHost.outcome(for: Odd()) else {
            Issue.record("an unknown error should be a server error")
            return
        }
    }

    @Test func readiness() {
        #expect(AppleModelHost.readiness(.available, readsImages: true) == .ready)
        #expect(AppleModelHost.readiness(.available, readsImages: false)
            == .never("Apple's model on this device doesn't read images"))
        #expect(AppleModelHost.readiness(.unavailable(.deviceNotEligible), readsImages: false)
            == .never("this device can't run Apple's model"))
        #expect(AppleModelHost.readiness(.unavailable(.modelNotReady), readsImages: false)
            == .waiting("Apple's model is still downloading"))
        #expect(AppleModelHost.readiness(.unavailable(.appleIntelligenceNotEnabled), readsImages: false)
            == .waiting("Apple Intelligence is off; turn it on in System Settings"))
    }

    @Test func identity() async {
        let host = AppleModelHost()
        let model = await host.model
        #expect(model?.id == "apple-on-device")
        #expect(model?.capabilities == [.text, .vision])
        #expect(model?.fingerprint.hasPrefix("apple-foundation-models-") == true)
        #expect(host.slots == 2)
        #expect(await host.availability == .starting("not started"))
        await #expect(throws: HostError.unavailable("Apple's model isn't ready")) {
            try await host.complete(Data("{}".utf8), timeout: 5)
        }
    }

    @Test func settingsSavedBeforeItExistedStillLoad() throws {
        let old = #"{"port":8090,"requireToken":true,"peers":[],"iCloudKeychain":true}"#
        let settings = try JSONDecoder().decode(NodeSettings.self, from: Data(old.utf8))
        #expect(settings.appleModel == AppleModelSettings())
        #expect(!settings.appleModel.enabled)
    }

    /// The real model. Set CONFLUX_TEST_APPLE_MODEL=1 on a Mac with Apple
    /// Intelligence turned on.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONFLUX_TEST_APPLE_MODEL"] != nil))
    func servesWithTheRealModel() async throws {
        let host = AppleModelHost()
        await host.start()
        let availability = await host.availability
        #expect(availability == .available, "\(availability)")
        let probe = try SelfCheck.probe(vision: true)
        let reply = try await host.complete(probe.body, timeout: 60)
        #expect(reply.status == 200)
        let answer = try #require(SelfCheck.answer(in: reply.body))
        #expect(SelfCheck.passes(answer: answer, expected: probe.expected), "\(answer)")
        let object = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
        let usage = object?["usage"] as? [String: Any]
        #expect((usage?["prompt_tokens"] as? Int ?? 0) > 0)
        // Far past its context: declined here, for another host.
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 2000)
        let body = try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": long]]])
        let tooLong = try await host.complete(body, timeout: 60)
        #expect(tooLong.status == 400 && tooLong.retryElsewhere, "\(String(decoding: tooLong.body, as: UTF8.self))")

        // An answer in the schema's shape, its properties in order.
        let shaped = try await host.complete(Data(#"""
            {"messages":[{"role":"user","content":"Describe a calm beach at noon."}],"temperature":0,
             "response_format":{"type":"json_schema","json_schema":{"name":"scene","schema":{"type":"object",
               "required":["summary","mood","people","tags"],"properties":{
                 "summary":{"type":"string"},"mood":{"enum":["calm","busy"]},
                 "people":{"type":"integer","minimum":0,"maximum":20},
                 "tags":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}}}}}}
            """#.utf8), timeout: 60)
        #expect(shaped.status == 200, "\(String(decoding: shaped.body, as: UTF8.self))")
        let shapedObject = try JSONSerialization.jsonObject(with: shaped.body) as? [String: Any]
        let message = (shapedObject?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let content = try #require(message?["content"] as? String)
        let shapedAnswer = try OrderedJSON.parse(Data(content.utf8))
        guard case .object(let members) = shapedAnswer else {
            Issue.record("not an object: \(content)")
            return
        }
        #expect(members.map { $0.key } == ["summary", "mood", "people", "tags"], "\(content)")
        #expect(["calm", "busy"].contains(shapedAnswer["mood"]?.string ?? ""), "\(content)")
        #expect((0...20).contains(shapedAnswer["people"]?.integer ?? -1), "\(content)")
        host.stop()
    }
}

/// A request one host declines goes to another that serves an accepted
/// model, and the client sees the decline only when there's none.
@Suite struct RetryElsewhereTests {
    let any = ModelChoice(model: "any", preference: nil)
    static let declined = HostReply(status: 400, body: ChatCompletionResult.error("declined", code: "content_filter"),
                                    retryElsewhere: true)

    @Test func anotherHostTakesWhatOneDeclines() async {
        let picky = FakeHost(id: "picky", model: "apple-on-device") { _ in Self.declined }
        let other = FakeHost(id: "other", model: "model-b", behavior: FakeHost.reply(after: 0.05))
        let scheduler = await Scheduler.with([picky, other])
        // The picky host is quicker, so it's tried first.
        await scheduler.setTypical(0.01, for: "picky")
        await scheduler.setTypical(1, for: "other")
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        guard case .completed(_, let model) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(model.id == "model-b")
        #expect(picky.callCount == 1)
        #expect(other.callCount == 1)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.hosts.allSatisfy { $0.failures.total == 0 })
    }

    @Test func theDeclineIsPassedOnWhenNoOtherHostCould() async {
        let picky = FakeHost(id: "picky", model: "apple-on-device") { _ in Self.declined }
        let scheduler = await Scheduler.with([picky])
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        guard case .rejected(let reply, let model) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(reply == Self.declined)
        #expect(model.id == "apple-on-device")
    }

    /// When every host declines, the refusal passed on names the last model
    /// that declined, which is the one whose refusal the client reads.
    @Test func theDeclinePassedOnNamesTheModelThatDeclined() async {
        let first = FakeHost(id: "first", model: "apple-on-device") { _ in Self.declined }
        let second = FakeHost(id: "second", model: "model-b") { _ in Self.declined }
        let scheduler = await Scheduler.with([first, second])
        await scheduler.setTypical(0.01, for: "first")
        await scheduler.setTypical(1, for: "second")
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        guard case .rejected(_, let model) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(first.callCount == 1)
        #expect(second.callCount == 1)
        #expect(model.id == "model-b")
    }

    @Test func onlyHostsServingAnAcceptedModelAreTried() async {
        let picky = FakeHost(id: "picky", model: "apple-on-device") { _ in Self.declined }
        let other = FakeHost(id: "other", model: "model-b")
        let scheduler = await Scheduler.with([picky, other])
        let onlyApple = ModelChoice(model: "apple-on-device", preference: nil)
        let outcome = await scheduler.submit(Data(), choice: onlyApple, deadline: Date().addingTimeInterval(10),
                                             key: nil)
        guard case .rejected(let reply, _) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(reply == Self.declined)
        #expect(other.callCount == 0)
    }

    @Test func anOrdinary400IsNotRetried() async {
        let bad = HostReply(status: 400, body: ChatCompletionResult.error("malformed"))
        let first = FakeHost(id: "first") { _ in bad }
        let second = FakeHost(id: "second", model: "model-b")
        let scheduler = await Scheduler.with([first, second])
        await scheduler.setTypical(0.01, for: "first")
        await scheduler.setTypical(1, for: "second")
        let outcome = await scheduler.submit(Data(), choice: any, deadline: Date().addingTimeInterval(10), key: nil)
        guard case .rejected(let reply, let model) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(reply == bad)
        #expect(model.id == "model-a")
        #expect(second.callCount == 0)
    }

    /// Across devices: the host protocol says `unsuitable`, and the gateway
    /// on the other device tries elsewhere.
    @Test func aPeersDeclineCanBeRetriedElsewhere() async throws {
        let peer = try await Peer(behavior: { _ in Self.declined })
        defer { peer.server.stop() }
        let reply = try await peer.remote.complete(Data("{}".utf8), timeout: 10)
        #expect(reply.status == 400)
        #expect(reply.retryElsewhere)
        // Named by the peer, so the gateway can say which model declined.
        #expect(reply.model?.id == "model-a")
        #expect(reply.model?.fingerprint == "fake-model-a")
    }
}
