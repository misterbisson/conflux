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
/// contains it with at most one character misread. Small models misread a
/// letter now and then; a model that can't see the image gets four of five
/// random characters right by chance about once in 50,000 tries. A text-only
/// model is asked to repeat a word instead.
public enum SelfCheck {
    /// No letters or digits that are easy to confuse with each other.
    static let alphabet = Array("ACDEFHJKLMNPRTUVWXY3479")

    public struct Probe: Sendable {
        public let expected: String
        public let body: Data
    }

    public static func probe(vision: Bool) throws -> Probe {
        let text = String((0..<5).map { _ in alphabet.randomElement()! })
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

    /// Passes when some run of the answer matches the expected text with at
    /// most `mistakes` characters different, ignoring case, spacing and
    /// punctuation.
    public static func passes(answer: String, expected: String, mistakes: Int = 1) -> Bool {
        func normalize(_ s: String) -> [Character] { Array(s.uppercased().filter { $0.isLetter || $0.isNumber }) }
        let answer = normalize(answer), expected = normalize(expected)
        guard !expected.isEmpty, answer.count >= expected.count else { return false }
        for start in 0...(answer.count - expected.count) {
            var wrong = 0
            for (offset, character) in expected.enumerated() where answer[start + offset] != character {
                wrong += 1
                if wrong > mistakes { break }
            }
            if wrong <= mistakes { return true }
        }
        return false
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
