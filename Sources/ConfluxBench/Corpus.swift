import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image, prepared once before a run so decoding and resizing never count
/// toward a request's time.
public struct CorpusImage: Sendable {
    public let name: String
    public let jpeg: Data
    public let width: Int
    public let height: Int
}

public enum Corpus {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    /// Loads up to `limit` images from `directory`, in name order, each
    /// downscaled to at most `maxDimension` on its longer side and re-encoded
    /// as JPEG.
    ///
    /// Re-encoding also drops EXIF and GPS metadata, so nothing about where an
    /// image was taken is sent to the server.
    public static func load(from directory: URL, maxDimension: Int, limit: Int) throws -> [CorpusImage] {
        let files: [URL]
        do {
            files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw BenchError("can't read \(directory.path): \(error.localizedDescription)")
        }
        guard !files.isEmpty else { throw BenchError("no images in \(directory.path)") }
        return try files.prefix(limit).map { try prepare($0, maxDimension: maxDimension) }
    }

    public static func prepare(_ url: URL, maxDimension: Int) throws -> CorpusImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw BenchError("can't open \(url.lastPathComponent)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BenchError("can't decode \(url.lastPathComponent)")
        }
        return CorpusImage(name: url.lastPathComponent, jpeg: try encodeJPEG(image),
                           width: image.width, height: image.height)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw BenchError("can't create a JPEG encoder") }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BenchError("can't encode JPEG") }
        return data as Data
    }
}
