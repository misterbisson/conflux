import Foundation
import Testing
@testable import ConfluxCore

/// A request's expected time from its size, once its host's pace is known
/// (docs/design.md, Deadlines).
@Suite struct RequestTimeTests {
    static func body(characters: Int, images: Int = 0, maxTokens: Int? = nil) -> Data {
        var content: [[String: Any]] = [["type": "text", "text": String(repeating: "a", count: characters)]]
        for _ in 0..<images { content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]) }
        var object: [String: Any] = ["messages": [["role": "user", "content": content]]]
        object["max_tokens"] = maxTokens
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// An answer as llama.cpp gives it: token counts, and how long reading
    /// and writing them took.
    static func answer(prompt: Int, read: Int? = nil, promptMs: Double, written: Int, writingMs: Double) -> Data {
        let object: [String: Any] = [
            "choices": [["message": ["content": "fine"]]], "model": "whatever",
            "usage": ["prompt_tokens": prompt, "completion_tokens": written],
            "timings": ["prompt_n": read ?? prompt, "prompt_ms": promptMs, "predicted_n": written,
                        "predicted_ms": writingMs],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Sizing requests

    @Test func sizesARequestFromItsBody() {
        let size = RequestSize(Self.body(characters: 120, images: 2, maxTokens: 64))
        #expect(size == RequestSize(characters: 120, images: 2, maxTokens: 64))
        let plain = Data(#"{"messages":[{"role":"system","content":"abcd"},{"role":"user","content":"efgh"}],"max_completion_tokens":9}"#.utf8)
        #expect(RequestSize(plain) == RequestSize(characters: 8, maxTokens: 9))
        #expect(RequestSize(Data("not json".utf8)) == RequestSize())
    }

    // MARK: Pacing hosts

    @Test func learnsAPaceFromTimings() throws {
        var pace = HostPace()
        // 400 characters, 100 tokens, plus 20 for the template.
        pace.record(RequestSize(characters: 400), reply: Self.answer(prompt: 120, promptMs: 1200, written: 10,
                                                                     writingMs: 1000), seconds: 2.5)
        #expect(pace.secondsPerPromptToken == 0.01)
        #expect(pace.secondsPerWrittenToken == 0.1)
        #expect(pace.templateTokens == 20)
        #expect(pace.written == 10)
        #expect(abs((pace.overhead ?? 0) - 0.3) < 1e-9)
        // The same again: 0.3 + 120 × 0.01 + 10 × 0.1.
        let same = try #require(pace.seconds(for: RequestSize(characters: 400)))
        #expect(abs(same - 2.5) < 1e-9)
        // A hundred times the text reads a hundred times the tokens.
        let long = try #require(pace.seconds(for: RequestSize(characters: 40_000)))
        #expect(abs(long - (0.3 + 10_020 * 0.01 + 1)) < 1e-9)
        // A limit below what it usually writes is what it writes.
        let short = try #require(pace.seconds(for: RequestSize(characters: 400, maxTokens: 2)))
        #expect(abs(short - (0.3 + 1.2 + 0.2)) < 1e-9)
    }

    @Test func imagesWaitForAnImageToBeTimed() throws {
        var pace = HostPace()
        pace.record(RequestSize(characters: 400), reply: Self.answer(prompt: 120, promptMs: 1200, written: 10,
                                                                     writingMs: 1000), seconds: 2.2)
        #expect(pace.seconds(for: RequestSize(characters: 400, images: 1)) == nil)
        // 100 text tokens, 20 for the template, so 280 for its image.
        pace.record(RequestSize(characters: 400, images: 1),
                    reply: Self.answer(prompt: 400, promptMs: 4000, written: 10, writingMs: 1000), seconds: 5.2)
        #expect(pace.tokensPerImage == 280)
        let two = try #require(pace.seconds(for: RequestSize(characters: 400, images: 2)))
        #expect(two > (pace.seconds(for: RequestSize(characters: 400, images: 1)) ?? .infinity))
    }

    @Test func readsOnlyWhatItRead() {
        var pace = HostPace()
        // llama-server reused 900 of the prompt's 1,000 tokens, and read 100 in a second.
        pace.record(RequestSize(characters: 4000), reply: Self.answer(prompt: 1000, read: 100, promptMs: 1000,
                                                                      written: 10, writingMs: 500), seconds: 2)
        #expect(pace.secondsPerPromptToken == 0.01)
    }

    @Test func anAnswerWithoutTimingsTeachesNothing() {
        var pace = HostPace()
        pace.record(RequestSize(characters: 400), reply: FakeHost.okBody, seconds: 1)
        #expect(pace == HostPace())
        #expect(pace.seconds(for: RequestSize(characters: 400)) == nil)
    }

    // MARK: Scheduling

    /// A host that reads 10 ms a token and writes 100 ms a token, by its
    /// answers, but answers at once.
    func pacedHost(_ id: String, model: String = "model-a") -> FakeHost {
        FakeHost(id: id, model: model,
                 behavior: FakeHost.reply(after: 0, body: Self.answer(prompt: 100, promptMs: 1000, written: 10,
                                                                      writingMs: 1000)))
    }

    @Test func aLongRequestIsntSentWhereItWouldMissItsDeadline() async {
        let host = pacedHost("h")
        let scheduler = await Scheduler.with([host])
        let any = ModelChoice(model: "any", preference: nil)
        // Times the host: 2 s for 400 characters, by its answer.
        _ = await scheduler.submit(Self.body(characters: 400), choice: any, deadline: nil, key: nil)
        let short = await scheduler.submit(Self.body(characters: 400), choice: any,
                                           deadline: Date().addingTimeInterval(10), key: nil)
        if case .completed = short {} else { Issue.record("\(short)") }
        // 40,000 characters would take it 100 s: not inside 10.
        let long = await scheduler.submit(Self.body(characters: 40_000), choice: any,
                                          deadline: Date().addingTimeInterval(10), key: nil)
        if case .busy = long {} else { Issue.record("\(long)") }
        #expect(host.callCount == 2)
    }

    @Test func aLongRequestGoesWhereItFinishesSoonest() async {
        // Both answer at once and take the same time for a short request,
        // but "quick" reads ten times faster.
        let slow = pacedHost("slow")
        let quick = FakeHost(id: "quick", behavior: FakeHost.reply(after: 0, body: Self.answer(
            prompt: 100, promptMs: 100, written: 10, writingMs: 1900)))
        let scheduler = await Scheduler.with([slow, quick])
        let choice = ModelChoice(model: "any", preference: nil)
        // Time each once, by sending to each alone.
        _ = await scheduler.submit(Self.body(characters: 400), choice: choice, deadline: nil, key: nil)
        _ = await scheduler.submit(Self.body(characters: 400), choice: choice, deadline: nil, key: nil)
        let snapshot = await scheduler.snapshot()
        guard snapshot.hosts.allSatisfy({ $0.pace.secondsPerPromptToken != nil }) else {
            Issue.record("not both timed: \(snapshot.hosts.map(\.id))")
            return
        }
        let before = quick.callCount
        _ = await scheduler.submit(Self.body(characters: 40_000), choice: choice, deadline: nil, key: nil)
        #expect(quick.callCount == before + 1)
    }

    @Test func aHostTurnsAwayAPeersRequestItCantFinish() async {
        let host = pacedHost("h")
        let scheduler = await Scheduler.with([host])
        _ = await scheduler.run(Self.body(characters: 400), onHost: "h", deadline: nil)
        let long = await scheduler.run(Self.body(characters: 40_000), onHost: "h",
                                       deadline: Date().addingTimeInterval(10))
        if case .busy = long {} else { Issue.record("\(long)") }
        let short = await scheduler.run(Self.body(characters: 400), onHost: "h",
                                        deadline: Date().addingTimeInterval(10))
        if case .completed = short {} else { Issue.record("\(short)") }
    }

    @Test func healthShowsThePace() async {
        let host = pacedHost("h")
        let scheduler = await Scheduler.with([host])
        _ = await scheduler.submit(Self.body(characters: 400), choice: ModelChoice(model: "any", preference: nil),
                                   deadline: nil, key: nil)
        let health = Gateway.health(await scheduler.snapshot())
        let entry = (health["hosts"] as? [[String: Any]])?.first
        let pace = entry?["pace"] as? [String: Any]
        #expect(pace?["seconds_per_1k_prompt_tokens"] as? Double == 10)
        #expect(pace?["seconds_per_1k_written_tokens"] as? Double == 100)
        #expect(pace?["written_tokens"] as? Double == 10)
        #expect(pace?["tokens_per_image"] == nil)
    }
}
