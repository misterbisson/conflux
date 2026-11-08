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
        #expect(throws: AppleModelRequest.Failure.unsuited("Apple's model here doesn't take response_format yet")) {
            try AppleModelRequest.parse(body(["messages": [message],
                                              "response_format": ["type": "json_schema", "json_schema": [:]]]))
        }
        #expect(throws: AppleModelRequest.Failure.unsuited("Apple's model here doesn't take tools")) {
            try AppleModelRequest.parse(body(["messages": [message], "tools": [["type": "function"]]]))
        }
        #expect((try? AppleModelRequest.parse(body(["messages": [message],
                                                     "response_format": ["type": "text"]]))) != nil)
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
        #expect(outcome == .rejected(Self.declined))
    }

    @Test func onlyHostsServingAnAcceptedModelAreTried() async {
        let picky = FakeHost(id: "picky", model: "apple-on-device") { _ in Self.declined }
        let other = FakeHost(id: "other", model: "model-b")
        let scheduler = await Scheduler.with([picky, other])
        let onlyApple = ModelChoice(model: "apple-on-device", preference: nil)
        let outcome = await scheduler.submit(Data(), choice: onlyApple, deadline: Date().addingTimeInterval(10),
                                             key: nil)
        #expect(outcome == .rejected(Self.declined))
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
        #expect(outcome == .rejected(bad))
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
    }
}
