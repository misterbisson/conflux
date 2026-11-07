import Foundation
import Testing
@testable import ConfluxBench

@Suite struct ChatTests {
    @Test func requestBody() throws {
        let body = ChatRequest.body(prompt: "Describe.", jpeg: Data([0xFF, 0xD8, 0xFF]), model: nil, maxTokens: 64)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] == nil)
        #expect(object["max_tokens"] as? Int == 64)
        #expect(object["temperature"] as? Int == 0)
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Describe.")
        let image = try #require(content.last?["image_url"] as? [String: Any])
        #expect(image["url"] as? String == "data:image/jpeg;base64,/9j/")
    }

    @Test func requestBodyNamesAModelWhenAsked() throws {
        let body = ChatRequest.body(prompt: "p", jpeg: Data(), model: "some-model", maxTokens: 1)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "some-model")
    }

    @Test func requestHeaders() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8080/v1/chat/completions"))
        let request = ChatRequest.urlRequest(url: url, body: Data(), token: "abc", timeout: 120, idempotencyKey: "k1")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "Conflux-Timeout") == "115")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k1")
        #expect(request.timeoutInterval == 120)
        let anonymous = ChatRequest.urlRequest(url: url, body: Data(), token: nil, timeout: 3, idempotencyKey: "k2")
        #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(anonymous.value(forHTTPHeaderField: "Conflux-Timeout") == "1")
    }

    @Test func parsesALlamaCppResponse() throws {
        let json = """
        {"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"A red square."}}],
         "model":"model-a.gguf","system_fingerprint":"b1234-abc",
         "usage":{"prompt_tokens":1070,"completion_tokens":42,"total_tokens":1112},
         "timings":{"prompt_ms":2100.5,"predicted_ms":4800.25}}
        """
        let result = try ChatResult.parse(Data(json.utf8))
        #expect(result.model == "model-a.gguf")
        #expect(result.fingerprint == "b1234-abc")
        #expect(result.promptTokens == 1070)
        #expect(result.completionTokens == 42)
        #expect(result.promptMs == 2100.5)
        #expect(result.predictedMs == 4800.25)
        #expect(result.finishReason == "stop")
        #expect(result.contentLength == 13)
    }

    @Test func modelPathsAreReducedToFileNames() throws {
        let json = #"{"choices":[{"message":{"content":"x"}}],"model":"/Users/someone/models/m.gguf"}"#
        #expect(try ChatResult.parse(Data(json.utf8)).model == "m.gguf")
    }

    @Test func parsesAMinimalResponse() throws {
        let result = try ChatResult.parse(Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        #expect(result.model == nil)
        #expect(result.promptMs == nil)
        #expect(result.contentLength == 2)
    }

    @Test func rejectsResponsesWithoutChoices() {
        #expect(throws: BenchError.self) { try ChatResult.parse(Data("[]".utf8)) }
        #expect(throws: BenchError.self) { try ChatResult.parse(Data(#"{"choices":[]}"#.utf8)) }
    }

    @Test func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)  // Sun, 09 Sep 2001 01:46:40 GMT
        #expect(RetryAfter.seconds("3", now: now) == 3)
        #expect(RetryAfter.seconds(" 0 ", now: now) == 0)
        #expect(RetryAfter.seconds("1.5", now: now) == 1.5)
        #expect(RetryAfter.seconds("Sun, 09 Sep 2001 01:46:50 GMT", now: now) == 10)
        #expect(RetryAfter.seconds("Sun, 09 Sep 2001 01:46:30 GMT", now: now) == 0)
        #expect(RetryAfter.seconds("-1", now: now) == nil)
        #expect(RetryAfter.seconds("soon", now: now) == nil)
        #expect(RetryAfter.seconds(nil, now: now) == nil)
    }
}
