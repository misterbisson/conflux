import Foundation

/// How much a request asks of a model, read from its body before it runs:
/// enough to tell how long it would take on a host that has been timed
/// (`HostPace`). Text is counted in characters, since the tokens depend on
/// the model.
public struct RequestSize: Sendable, Equatable, Hashable {
    /// Characters of text in its messages.
    public var characters: Int
    public var images: Int
    /// `max_completion_tokens` or `max_tokens`, when it says.
    public var maxTokens: Int?

    public init(characters: Int = 0, images: Int = 0, maxTokens: Int? = nil) {
        self.characters = characters
        self.images = images
        self.maxTokens = maxTokens
    }

    /// From an OpenAI chat completion body. A body that isn't one is sized
    /// as nothing, and the runtime refuses it.
    public init(_ body: Data) {
        self.init()
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        for message in object["messages"] as? [[String: Any]] ?? [] {
            switch message["content"] {
            case let text as String:
                characters += text.count
            case let parts as [[String: Any]]:
                for part in parts {
                    switch part["type"] as? String {
                    case "text": characters += (part["text"] as? String)?.count ?? 0
                    case "image_url": images += 1
                    default: break
                    }
                }
            default:
                break
            }
        }
        let limit = object["max_completion_tokens"] ?? object["max_tokens"]
        maxTokens = (limit as? NSNumber)?.intValue
    }
}

/// How quickly one host runs requests, learned from the answers it
/// completed: seconds for each prompt token read and each token written,
/// from the timings each answer carries, how many tokens its model makes of
/// text and of an image, how much it usually writes, and the time left over,
/// such as the network's. Each is weighted towards recent answers, like a
/// host's typical time, so a host that warms up or throttles is followed
/// within a few requests (docs/design.md, Deadlines).
///
/// Apple's model reports no timings, so it's never paced, and its typical
/// time stands.
public struct HostPace: Sendable, Equatable {
    public internal(set) var secondsPerPromptToken: Double?
    public internal(set) var secondsPerWrittenToken: Double?
    /// Prompt tokens beyond the text's: the chat template's.
    public internal(set) var templateTokens: Double?
    public internal(set) var tokensPerImage: Double?
    /// Tokens written, usually.
    public internal(set) var written: Double?
    /// Seconds beyond reading and writing: the network, waiting for the
    /// runtime, and anything else.
    public internal(set) var overhead: Double?

    public init() {}

    /// About right for English across these models' tokenizers. What it
    /// misses, the template's tokens take up.
    static let charactersPerToken = 4.0

    /// What a completed answer says, if it carries timings.
    struct Reading: Equatable {
        var promptTokens: Int
        var writtenTokens: Int
        /// Tokens read, and the seconds that took. Fewer tokens than the
        /// prompt's when `llama-server` reused the start of an earlier one.
        var promptRead: Int
        var promptSeconds: Double
        var writingSeconds: Double

        init?(_ body: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let usage = object["usage"] as? [String: Any], let timings = object["timings"] as? [String: Any]
            else { return nil }
            func number(_ dictionary: [String: Any], _ key: String) -> Double? {
                (dictionary[key] as? NSNumber)?.doubleValue
            }
            guard let prompt = number(usage, "prompt_tokens"), let written = number(usage, "completion_tokens"),
                  let promptMs = number(timings, "prompt_ms"), let writingMs = number(timings, "predicted_ms")
            else { return nil }
            promptTokens = Int(prompt)
            writtenTokens = Int(written)
            promptRead = Int(number(timings, "prompt_n") ?? prompt)
            promptSeconds = max(0, promptMs / 1000)
            writingSeconds = max(0, writingMs / 1000)
        }
    }

    mutating func record(_ size: RequestSize, reply body: Data, seconds: Double) {
        guard let reading = Reading(body) else { return }
        func weigh(_ old: Double?, _ new: Double) -> Double { old.map { 0.7 * $0 + 0.3 * new } ?? new }
        if reading.promptRead > 0 {
            secondsPerPromptToken = weigh(secondsPerPromptToken, reading.promptSeconds / Double(reading.promptRead))
        }
        if reading.writtenTokens > 0 {
            secondsPerWrittenToken = weigh(secondsPerWrittenToken,
                                           reading.writingSeconds / Double(reading.writtenTokens))
        }
        let beyondText = max(0, Double(reading.promptTokens) - Double(size.characters) / Self.charactersPerToken)
        if size.images > 0 {
            let images = max(0, beyondText - (templateTokens ?? 0)) / Double(size.images)
            tokensPerImage = weigh(tokensPerImage, images)
        } else {
            templateTokens = weigh(templateTokens, beyondText)
        }
        written = weigh(written, Double(reading.writtenTokens))
        overhead = weigh(overhead, max(0, seconds - reading.promptSeconds - reading.writingSeconds))
    }

    /// The tokens a request's prompt is likely to come to, once the host
    /// has been timed on requests like it: with images, once it has read
    /// one.
    func promptTokens(_ size: RequestSize) -> Double? {
        var tokens = Double(size.characters) / Self.charactersPerToken + (templateTokens ?? 0)
        if size.images > 0 {
            guard let tokensPerImage else { return nil }
            tokens += tokensPerImage * Double(size.images)
        }
        return tokens
    }

    /// Seconds a request is likely to take here, or nil until the host has
    /// been timed. It writes what the host usually writes, or `maxTokens`
    /// if that's fewer: most answers stop well before their limit.
    func seconds(for size: RequestSize) -> Double? {
        guard let secondsPerPromptToken, let secondsPerWrittenToken, let written, let overhead,
              let prompt = promptTokens(size) else { return nil }
        let writing = min(written, size.maxTokens.map(Double.init) ?? .infinity)
        return overhead + prompt * secondsPerPromptToken + writing * secondsPerWrittenToken
    }
}
