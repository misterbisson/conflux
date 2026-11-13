import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Proves a model actually reads what it's sent before its host reports
/// Ready (docs/design.md, *Self-check*).
///
/// A vision model whose projector fails doesn't report the failure: it
/// describes an image it never saw, fluently. So the check renders a short
/// random string, asks the model to read it back, and passes if the answer
/// contains it with at most one character misread, added or dropped, or one
/// pair of neighbours swapped. Small models misread a letter now and then,
/// or swap two, and Apple's model sometimes adds one; a model that can't see the image comes that close by chance well
/// under once in 10,000 tries. A text-only model is asked to repeat a word
/// instead.
public enum SelfCheck {
    /// No letters or digits that are easy to confuse with each other.
    static let alphabet = Array("ACDEFHJKLMNPRTUVWXY3479")

    public struct Probe: Sendable {
        public let expected: String
        public let body: Data
    }

    public static func probe(vision: Bool) throws -> Probe {
        let text = String(randomText())
        var content: [[String: Any]]
        if vision {
            // Spaced apart, so neighbouring letters don't run together.
            let jpeg = try render(text.map(String.init).joined(separator: " "))
            content = [
                ["type": "text", "text": "What text is shown in this image? Reply with the text only."],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
            ]
        } else {
            content = [["type": "text", "text": "Reply with exactly this and nothing else: \(text)"]]
        }
        let body: [String: Any] = [
            "messages": [["role": "user", "content": content]],
            "max_tokens": 24, "temperature": 0, "stream": false,
        ]
        return Probe(expected: text, body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Five characters, never the same one twice in a row. Small vision
    /// models read a doubled letter as one: the starter model misread almost
    /// nothing else (docs/plan.md, Phase 4). A dropped letter fails the
    /// check, so without this a working model failed it now and then.
    static func randomText(count: Int = 5) -> [Character] {
        var text: [Character] = []
        while text.count < count {
            let next = alphabet.randomElement()!
            if next != text.last { text.append(next) }
        }
        return text
    }

    /// Passes when some run of the answer matches the expected text with at
    /// most `mistakes` characters changed, added or dropped, or neighbours
    /// swapped, ignoring case, spacing and punctuation.
    public static func passes(answer: String, expected: String, mistakes: Int = 1) -> Bool {
        func normalize(_ s: String) -> [Character] { Array(s.uppercased().filter { $0.isLetter || $0.isNumber }) }
        let answer = normalize(answer), expected = normalize(expected)
        guard !expected.isEmpty else { return false }
        let shortest = max(1, expected.count - mistakes), longest = expected.count + mistakes
        guard answer.count >= shortest else { return false }
        for length in shortest...min(longest, answer.count) {
            for start in 0...(answer.count - length)
            where distance(Array(answer[start..<(start + length)]), expected) <= mistakes {
                return true
            }
        }
        return false
    }

    /// Edits that turn `a` into `b`: a character changed, added or dropped,
    /// or two neighbours swapped, each counting as one. Small vision models
    /// swap neighbouring letters now and then: the starter model read HMRVK
    /// as HMVRK on an iPad.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var before: [Int] = [], previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                var edits = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
                if i > 0, j > 0, x == b[j - 1], a[i - 1] == y { edits = min(edits, before[j - 1] + 1) }
                current.append(edits)
            }
            (before, previous) = (previous, current)
        }
        return previous[b.count]
    }

    /// Runs `probes` checks through `complete`, each with fresh text. Nil
    /// when all pass, otherwise what went wrong. All must pass: a working
    /// model reads them every time, while one that reads its input badly
    /// gets some right by luck, and a single probe wouldn't tell the two
    /// apart.
    public static func run(vision: Bool, probes: Int = 3,
                           complete: (Data) async throws -> HostReply) async -> String? {
        var misses: [String] = []
        for _ in 0..<probes {
            do {
                let probe = try SelfCheck.probe(vision: vision)
                let reply = try await complete(probe.body)
                guard (200..<300).contains(reply.status) else {
                    let detail = String(decoding: reply.body.prefix(200), as: UTF8.self)
                    return "the model answered \(reply.status): \(detail)"
                }
                let answer = SelfCheck.answer(in: reply.body) ?? ""
                if !SelfCheck.passes(answer: answer, expected: probe.expected) {
                    misses.append("asked to read \(probe.expected), it answered \(answer.prefix(60).debugDescription)")
                }
            } catch {
                return "\(error)"
            }
        }
        guard let first = misses.first else { return nil }
        return "\(misses.count) of \(probes) misread; \(first)"
    }

    /// llama.cpp's own suggestions for a model that may read its input
    /// badly, from its warnings: "if you encounter problems with accuracy,
    /// try adding --image-min-tokens 1024". Passed on to the person, since
    /// the fix depends on the model.
    public static func advice(in log: String) -> String? {
        let suggestions = log.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let range = line.range(of: "try adding ", options: .caseInsensitive) else { return nil }
            let suggestion = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return suggestion.hasPrefix("-") ? "add \(suggestion)" : nil
        }
        var seen: Set<String> = []
        let unique = suggestions.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "; ")
    }

    /// The text of the first choice in a chat completion response.
    public static func answer(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return nil }
        return message["content"] as? String
    }

    static func render(_ text: String) throws -> Data {
        let width = 768, height = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                       y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.featureUnsupported) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.featureUnsupported) }
        return data as Data
    }
}
