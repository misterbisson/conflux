import Foundation

/// Building an OpenAI-compatible chat request with one image, the way a
/// conflux client is expected to send it (docs/clients.md).
public enum ChatRequest {
    public static func body(prompt: String, jpeg: Data, model: String?, maxTokens: Int) -> Data {
        var body: [String: Any] = [
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ],
            ]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": false,
        ]
        if let model { body["model"] = model }
        // Keys sorted so the same request always produces the same bytes.
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// The deadline header is a few seconds under the HTTP timeout, so the
    /// server's answer, even a 429, arrives before this side gives up.
    public static func urlRequest(url: URL, body: Data, token: String?, timeout: TimeInterval,
                                  idempotencyKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(max(1, Int(timeout) - 5)), forHTTPHeaderField: "Conflux-Timeout")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// What one response says about itself. Every field is optional except the
/// content length, because servers differ in what they report.
public struct ChatResult: Sendable, Equatable {
    public var model: String?
    public var fingerprint: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// llama.cpp's `timings`: time spent reading the prompt, including the
    /// image, and time spent generating.
    public var promptMs: Double?
    public var predictedMs: Double?
    public var finishReason: String?
    public var contentLength = 0

    public static func parse(_ data: Data) throws -> ChatResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchError("response is not a JSON object")
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw BenchError("response has no choices")
        }
        var result = ChatResult()
        result.model = object["model"] as? String
        result.fingerprint = object["system_fingerprint"] as? String
        if let usage = object["usage"] as? [String: Any] {
            result.promptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue
            result.completionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue
        }
        if let timings = object["timings"] as? [String: Any] {
            result.promptMs = (timings["prompt_ms"] as? NSNumber)?.doubleValue
            result.predictedMs = (timings["predicted_ms"] as? NSNumber)?.doubleValue
        }
        result.finishReason = first["finish_reason"] as? String
        let message = first["message"] as? [String: Any]
        result.contentLength = (message?["content"] as? String)?.count ?? 0
        return result
    }
}

public enum RetryAfter {
    /// Seconds to wait, from a `Retry-After` value: either delta-seconds or
    /// an HTTP date. Nil when absent or unreadable.
    public static func seconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
