import Foundation
import ImageIO
import Testing
@testable import ConfluxBench

@Suite struct CorpusTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "conflux-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatedImagesLoadAndDownscale() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try SyntheticImages.write(count: 3, size: 512, seed: 7, to: directory)
        #expect(urls.map(\.lastPathComponent) == ["synthetic-0001.jpg", "synthetic-0002.jpg", "synthetic-0003.jpg"])

        let corpus = try Corpus.load(from: directory, maxDimension: 256, limit: 2)
        #expect(corpus.count == 2)
        for image in corpus {
            #expect(max(image.width, image.height) == 256)
            #expect(image.jpeg.starts(with: [0xFF, 0xD8]))
        }
    }

    @Test func sameSeedSamePictures() throws {
        let a = try scratch(), b = try scratch()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try SyntheticImages.write(count: 2, size: 128, seed: 42, to: a)
        let second = try SyntheticImages.write(count: 2, size: 128, seed: 42, to: b)
        for (x, y) in zip(first, second) { #expect(try Data(contentsOf: x) == Data(contentsOf: y)) }
    }

    @Test func reencodingDropsLocationMetadata() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A JPEG carrying a GPS position, as a phone would write it.
        let plain = try #require(try SyntheticImages.write(count: 1, size: 128, seed: 1, to: directory).first)
        let source = try #require(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let tagged = directory.appending(path: "tagged.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(tagged as CFURL, "public.jpeg" as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 1.5, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 1.5, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try FileManager.default.removeItem(at: plain)
        let original = try #require(CGImageSourceCreateWithURL(tagged as CFURL, nil))
        let before = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any]
        #expect(before?[kCGImagePropertyGPSDictionary] != nil, "the test image should carry a location")

        let prepared = try Corpus.prepare(tagged, maxDimension: 128)
        let reread = try #require(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(reread, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func emptyDirectoryIsAnError() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: BenchError.self) { try Corpus.load(from: directory, maxDimension: 256, limit: 10) }
    }
}
