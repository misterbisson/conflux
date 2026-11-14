import Foundation

/// An OpenAI chat completion request, as Apple's on-device model takes it:
/// instructions, the conversation so far, and the user's last message, each
/// message a run of text and images.
///
/// Kept apart from the Foundation Models types, so it can be tested on a
/// machine without Apple Intelligence, as CI's runners are.
struct AppleModelRequest: Equatable {
    enum Part: Equatable {
        case text(String)
        /// An encoded image (JPEG, PNG and so on).
        case image(Data)
    }

    struct Turn: Equatable {
        enum Role: Equatable { case user, assistant }
        var role: Role
        var parts: [Part]
    }

    /// The system and developer messages, joined.
    var instructions: String?
    /// The messages before the last one.
    var history: [Turn] = []
    /// The last message, the user's.
    var prompt: [Part] = []
    var maxTokens: Int?
    /// Nil: the model's own.
    var temperature: Double?
    var stop: [String] = []
    /// The answer's shape, from `response_format`; nil for text.
    var schema: AppleModelSchema?

    enum Failure: Error, Equatable {
        /// The client's fault: 400 from any host.
        case invalid(String)
        /// Something this model doesn't do, though another host might: the
        /// gateway tries one.
        case unsuited(String)
    }

    /// Stands in for an image while the existing parser joins each
    /// message's parts: U+FFFC, the object replacement character.
    static let marker = "\u{FFFC}"

    static func parse(_ body: Data) throws(Failure) -> AppleModelRequest {
        let parsed: ChatCompletionRequest
        do {
            parsed = try ChatCompletionRequest.parse(body, marker: marker)
        } catch {
            throw .invalid(error.message)
        }
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let schema = try AppleModelSchema.parse(body)
        // What Apple's model can't do yet, but a llama.cpp host can.
        if let tools = object["tools"] as? [Any], !tools.isEmpty {
            throw .unsuited("Apple's model here doesn't take tools")
        }

        var request = AppleModelRequest()
        var images = parsed.images.makeIterator()
        func parts(_ text: String) -> [Part] {
            var parts: [Part] = []
            for (index, piece) in text.components(separatedBy: marker).enumerated() {
                if index > 0, let image = images.next() { parts.append(.image(image)) }
                if !piece.isEmpty { parts.append(.text(piece)) }
            }
            return parts
        }
        var instructions: [String] = []
        var turns: [Turn] = []
        for message in parsed.messages {
            switch message.role {
            case "system":
                if message.text.contains(marker) { throw .invalid("a system message can't hold images") }
                instructions.append(message.text)
            case "user":
                turns.append(Turn(role: .user, parts: parts(message.text)))
            case "assistant":
                if message.text.contains(marker) { throw .invalid("an assistant message can't hold images") }
                turns.append(Turn(role: .assistant, parts: parts(message.text)))
            case let role:
                throw .unsuited("Apple's model here doesn't take \(role) messages")
            }
        }
        guard let last = turns.popLast(), last.role == .user else {
            throw .invalid("the last message must be the user's")
        }
        request.instructions = instructions.isEmpty ? nil : instructions.joined(separator: "\n\n")
        request.history = turns
        request.prompt = last.parts
        request.maxTokens = parsed.maxTokens
        request.temperature = (object["temperature"] as? NSNumber)?.doubleValue
        request.stop = parsed.stop
        request.schema = schema
        return request
    }

    var imageCount: Int {
        (history.flatMap(\.parts) + prompt).filter { if case .image = $0 { true } else { false } }.count
    }
}
