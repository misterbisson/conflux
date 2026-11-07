import CoreGraphics
import CoreText
import Foundation

/// Generated test images: shapes and a short line of text on a plain
/// background.
///
/// They contain nothing personal, so they're safe to commit, share and run in
/// CI. They're good for measuring throughput and for checking that a server
/// reads images at all. They aren't a stand-in for real images when judging
/// answer quality, and output length on them may differ from real workloads.
public enum SyntheticImages {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Writes `count` JPEGs named `synthetic-0001.jpg` and so on. The same
    /// seed gives the same pictures.
    @discardableResult
    public static func write(count: Int, size: Int, seed: UInt64, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: seed)
        return try (1...max(1, count)).map { number in
            let url = directory.appending(path: String(format: "synthetic-%04d.jpg", number))
            try Corpus.encodeJPEG(try render(size: size, rng: &rng)).write(to: url)
            return url
        }
    }

    static func render(size: Int, rng: inout SplitMix64) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw BenchError("can't create a drawing context") }

        let side = CGFloat(size)
        context.setFillColor(color(&rng, light: true))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        for _ in 0..<(3 + Int(rng.next() % 6)) {
            let rect = CGRect(x: side * rng.unit(), y: side * rng.unit(),
                              width: side * (0.1 + 0.4 * rng.unit()),
                              height: side * (0.1 + 0.4 * rng.unit()))
            context.setFillColor(color(&rng, light: false))
            if rng.next() % 2 == 0 { context.fill(rect) } else { context.fillEllipse(in: rect) }
        }

        let length = 4 + Int(rng.next() % 5)
        let text = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, side / 8, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: side * 0.08, y: side * (0.1 + 0.7 * rng.unit()))
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { throw BenchError("can't render an image") }
        return image
    }

    static func color(_ rng: inout SplitMix64, light: Bool) -> CGColor {
        let base = light ? 0.75 : 0.1
        let range = light ? 0.25 : 0.7
        return CGColor(srgbRed: base + range * rng.unit(), green: base + range * rng.unit(),
                       blue: base + range * rng.unit(), alpha: 1)
    }
}

/// A small, seedable generator, so generated corpora are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in [0, 1).
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}
