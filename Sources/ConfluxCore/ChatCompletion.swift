import Foundation

/// An OpenAI chat completion request, as the in-process runtime needs it:
/// each message's text, with a marker where each image goes, and the images
/// in order.
struct ChatCompletionRequest: Equatable {
    struct Message: Equatable {
        var role: String
        var text: String
    }

    var messages: [Message] = []
    /// Encoded images (JPEG, PNG and so on), in the order their markers
    /// appear.
    var images: [Data] = []
    /// Nil: until the model stops or the context is full.
    var maxTokens: Int?
    var temperature = 0.8
    var topK = 40
    var topP = 0.95
    var minP = 0.05
    var seed: UInt32?
    var stop: [String] = []

    /// A request the runtime can't run. The client's fault: 400.
    struct Invalid: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Defaults follow llama-server's, so the two runtimes answer alike.
    static func parse(_ body: Data, marker: String) throws(Invalid) -> ChatCompletionRequest {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Invalid("the body isn't a JSON object")
        }
        guard let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw Invalid("messages must be a non-empty array")
        }
        var request = ChatCompletionRequest()
        for message in messages {
            guard var role = message["role"] as? String else { throw Invalid("each message needs a role") }
            if role == "developer" { role = "system" }
            var text = ""
            switch message["content"] {
            case let string as String:
                text = string
            case let parts as [[String: Any]]:
                // As llama.cpp joins parts: a newline between text parts,
                // none next to an image.
                var afterImage = false
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        let piece = part["text"] as? String ?? ""
                        if !afterImage && !text.isEmpty { text += "\n" }
                        text += piece
                        afterImage = false
                    case "image_url":
                        let url = (part["image_url"] as? [String: Any])?["url"] as? String
                            ?? part["image_url"] as? String
                        guard let url else { throw Invalid("image_url needs a url") }
                        request.images.append(try image(from: url))
                        text += marker
                        afterImage = true
                    case let type:
                        throw Invalid("content of type \(type ?? "none") isn't supported")
                    }
                }
            case nil, is NSNull:
                text = ""
            default:
                throw Invalid("content must be a string or an array of parts")
            }
            request.messages.append(Message(role: role, text: text))
        }

        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        if let tokens = number("max_completion_tokens") ?? number("max_tokens") {
            guard tokens >= 1 else { throw Invalid("max_tokens must be at least 1") }
            request.maxTokens = Int(tokens)
        }
        request.temperature = number("temperature") ?? request.temperature
        request.topP = number("top_p") ?? request.topP
        request.minP = number("min_p") ?? request.minP
        request.topK = number("top_k").map { Int($0) } ?? request.topK
        request.seed = number("seed").map { UInt32(truncatingIfNeeded: Int64($0)) }
        switch object["stop"] {
        case let stop as String: request.stop = [stop]
        case let stop as [String]: request.stop = stop
        default: break
        }
        request.stop.removeAll { $0.isEmpty }
        if (object["n"] as? NSNumber).map({ $0.intValue != 1 }) == true {
            throw Invalid("n must be 1")
        }
        return request
    }

    /// Only `data:` URLs: the runtime doesn't fetch anything.
    static func image(from url: String) throws(Invalid) -> Data {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64")
        else { throw Invalid("images must be base64 data: URLs") }
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...]),
                              options: .ignoreUnknownCharacters), !data.isEmpty
        else { throw Invalid("an image's base64 data doesn't decode") }
        return data
    }
}

/// What one generation produced, and how long it took.
struct ChatCompletionResult: Equatable {
    var text: String
    /// "stop" when the model finished or hit a stop string, "length" at the
    /// token limit.
    var finishReason: String
    var promptTokens: Int
    var completionTokens: Int
    var promptMs: Double
    var predictedMs: Double

    /// In llama-server's shape, `timings` included, so clients and the
    /// benchmark read both runtimes the same way. The gateway sets `model`
    /// and `system_fingerprint`.
    func body(model: String, created: Date = Date()) -> Data {
        func perSecond(_ count: Int, _ ms: Double) -> Double { ms > 0 ? Double(count) * 1000 / ms : 0 }
        let object: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.lowercased())",
            "object": "chat.completion",
            "created": Int(created.timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": finishReason,
            ]],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
            "timings": [
                "prompt_n": promptTokens,
                "prompt_ms": promptMs,
                "prompt_per_second": perSecond(promptTokens, promptMs),
                "predicted_n": completionTokens,
                "predicted_ms": predictedMs,
                "predicted_per_second": perSecond(completionTokens, predictedMs),
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// An error in OpenAI's shape, for a status the gateway passes through.
    static func error(_ message: String, type: String = "invalid_request_error") -> Data {
        let object = ["error": ["message": message, "type": type]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

extension ChatCompletionRequest {
    /// The text cut just before the first stop string in it, or nil if it
    /// has none.
    static func truncate(_ text: String, atFirstOf stops: [String]) -> String? {
        let cuts = stops.compactMap { text.range(of: $0)?.lowerBound }
        return cuts.min().map { String(text[..<$0]) }
    }
}
