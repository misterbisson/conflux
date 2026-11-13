import Foundation
import Synchronization

/// What a GGUF file's header says about it: enough to tell a vision projector
/// from a model, whether a projector fits a model, and how much memory a
/// model's context takes.
///
/// Read from the header's key/value pairs, never the tensors. The keys are
/// llama.cpp's: its converter writes them, and its loaders read them.
public struct GGUFMetadata: Sendable, Equatable {
    /// The GGUF version: 2 or 3.
    public var version: UInt32
    /// `general.architecture`: `clip` for a projector, otherwise the model's
    /// architecture, such as `llama` or `qwen2vl`.
    public var architecture: String?
    /// `general.name`, such as "SmolVLM 256M Instruct".
    public var name: String?
    /// `general.basename`, the name without its size or fine-tune, such as
    /// "SmolVLM".
    public var basename: String?
    /// A model's `<architecture>.embedding_length`: how wide the vectors its
    /// layers take are.
    public var embeddingLength: Int?
    /// A projector's `clip.vision.projection_dim`: how wide the vectors it
    /// gives the model for an image are. llama.cpp's converter writes the
    /// model's embedding length here, so a projector fits a model when the
    /// two are equal. Nil when the file doesn't say, or was written by one of
    /// llama.cpp's older converters, which wrote the image encoder's own width
    /// here instead.
    public var imageWidth: Int?
    /// `clip.has_vision_encoder`: the projector reads images.
    public var hasVisionEncoder: Bool?
    /// `clip.has_audio_encoder`: the projector reads audio.
    public var hasAudioEncoder: Bool?

    // What a model's context takes in memory (ModelFit): llama.cpp keeps a
    // key and a value for each token, in each layer, for each key/value head.

    /// A model's `<architecture>.block_count`: how many layers it has.
    public var blockCount: Int?
    /// A model's `<architecture>.context_length`: the most tokens it was
    /// trained to read at once.
    public var contextLength: Int?
    /// A model's `<architecture>.attention.head_count`: how many attention
    /// heads it has. Where the file gives a count for each layer, the
    /// smallest that isn't 0, so a head width worked out from it errs wide.
    public var headCount: Int?
    /// A model's `<architecture>.attention.head_count_kv`: how many heads its
    /// keys and values have. One count for every layer, or, for a model whose
    /// layers differ, one for each, with 0 for a layer without attention. Nil
    /// when the file doesn't say, which llama.cpp reads as `headCount`.
    public var headCountKV: [Int]?
    /// A model's `<architecture>.attention.key_length`: how wide each head's
    /// keys are. Nil when the file doesn't say, which llama.cpp reads as the
    /// embedding length over the head count.
    public var keyLength: Int?
    /// A model's `<architecture>.attention.value_length`: the same, for
    /// values.
    public var valueLength: Int?

    public init(version: UInt32 = 3, architecture: String? = nil, name: String? = nil, basename: String? = nil,
                embeddingLength: Int? = nil, imageWidth: Int? = nil, hasVisionEncoder: Bool? = nil,
                hasAudioEncoder: Bool? = nil, blockCount: Int? = nil, contextLength: Int? = nil,
                headCount: Int? = nil, headCountKV: [Int]? = nil, keyLength: Int? = nil, valueLength: Int? = nil) {
        self.version = version
        self.architecture = architecture
        self.name = name
        self.basename = basename
        self.embeddingLength = embeddingLength
        self.imageWidth = imageWidth
        self.hasVisionEncoder = hasVisionEncoder
        self.hasAudioEncoder = hasAudioEncoder
        self.blockCount = blockCount
        self.contextLength = contextLength
        self.headCount = headCount
        self.headCountKV = headCountKV
        self.keyLength = keyLength
        self.valueLength = valueLength
    }

    /// A multimodal projector, llama.cpp's mmproj: its architecture is `clip`.
    public var isProjector: Bool { architecture == "clip" }

    /// A projector that reads images. Older projectors don't say, and all of
    /// them read images.
    public var readsImages: Bool { isProjector && (hasVisionEncoder ?? (hasAudioEncoder != true)) }
}

/// Why a GGUF header couldn't be read.
public enum GGUFError: Error, Equatable, Sendable, LocalizedError {
    /// The file couldn't be opened or read, and why, in words for the window.
    case unreadable(String)
    /// It doesn't start with GGUF.
    case notGGUF
    /// A version other than 2 or 3.
    case unsupportedVersion(UInt32)
    /// It ends partway through its header.
    case truncated
    /// Its header is damaged, or not what llama.cpp writes.
    case corrupt(String)
    /// Its header is larger than any real model's.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): why
        case .notGGUF: "it isn't a GGUF file"
        case .unsupportedVersion(let version): "it's GGUF version \(version), and conflux reads versions 2 and 3"
        case .truncated: "it ends partway through its header, so it's incomplete"
        case .corrupt(let why): "its header is damaged: \(why)"
        case .tooLarge: "its header is larger than any model's"
        }
    }
}

extension GGUFMetadata {
    /// Limits that keep a damaged or hostile file from making the reader
    /// allocate wildly or run long. Real headers are far inside them: a few
    /// dozen keys, and a tokenizer of a few hundred thousand strings in tens
    /// of megabytes.
    enum Limits {
        static let headerBytes: UInt64 = 256 << 20
        static let keys: UInt64 = 1 << 16
        static let keyLength: UInt64 = 1 << 16
        static let tensors: UInt64 = 1 << 24
        /// Longer names are skipped, not kept.
        static let keptString: UInt64 = 4096
        /// Longer lists of counts, one for each layer, are skipped, not kept.
        static let layers: UInt64 = 1 << 12
        /// Larger widths, counts and context lengths aren't believed.
        static let dimension = 1 << 24
    }

    /// Reads the header of the GGUF file at `url`.
    public static func read(from url: URL) throws(GGUFError) -> GGUFMetadata {
        let handle: FileHandle
        let size: UInt64
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw .unreadable("it can't be opened")
        }
        defer { try? handle.close() }
        var reader = GGUFReader(source: handle, size: size)
        return try parse(&reader)
    }

    /// Reads a header from bytes in memory, for tests.
    static func read(from data: Data) throws(GGUFError) -> GGUFMetadata {
        var reader = GGUFReader(source: DataSource(data: data), size: UInt64(data.count))
        return try parse(&reader)
    }

    private static func parse(_ reader: inout GGUFReader) throws(GGUFError) -> GGUFMetadata {
        guard reader.size >= 4 else { throw reader.size == 0 ? .notGGUF : .truncated }
        guard try reader.bytes(4).elementsEqual("GGUF".utf8) else { throw .notGGUF }
        let version = try reader.u32()
        // Version 1 counted in 32 bits, and llama.cpp no longer reads it.
        guard version == 2 || version == 3 else { throw .unsupportedVersion(version) }
        let tensors = try reader.u64()
        let keys = try reader.u64()
        guard tensors <= Limits.tensors else { throw .corrupt("it claims \(tensors) tensors") }
        guard keys <= Limits.keys else { throw .corrupt("it claims \(keys) keys") }

        var metadata = GGUFMetadata(version: version)
        /// A model's hyperparameters, by key: kept for every architecture,
        /// since the file may name its own after them.
        var hyperparameters: [String: [Int]] = [:]
        var projectionWidth: Int?
        /// Written only by llama.cpp's older converters, whose projection_dim
        /// is the image encoder's own width.
        var legacy = false
        /// Whether this is a model, and its names and the hyperparameters
        /// `suffixes` are known.
        func known(_ suffixes: [String]) -> Bool {
            guard let architecture = metadata.architecture, !metadata.isProjector, metadata.name != nil,
                  metadata.basename != nil else { return false }
            return suffixes.allSatisfy { hyperparameters[architecture + $0] != nil }
        }
        for _ in 0..<keys {
            let length = try reader.u64()
            guard length <= Limits.keyLength else { throw .corrupt("a key \(length) bytes long") }
            let key = String(decoding: try reader.bytes(Int(length)), as: UTF8.self)
            let type = try reader.u32()
            // A model's tokenizer is most of its header, and llama.cpp's
            // converter writes the model's hyperparameters before it. One
            // that isn't written by then, such as key_length for a model
            // whose heads are the usual width, isn't written: stop.
            if key.hasPrefix("tokenizer."), known(Hyperparameter.always) { break }
            switch key {
            case "general.architecture": metadata.architecture = try reader.string(type)
            case "general.name": metadata.name = try reader.string(type)
            case "general.basename": metadata.basename = try reader.string(type)
            case "clip.vision.projection_dim": projectionWidth = try reader.integer(type)
            case "clip.has_vision_encoder": metadata.hasVisionEncoder = try reader.bool(type)
            case "clip.has_audio_encoder": metadata.hasAudioEncoder = try reader.bool(type)
            case "clip.has_text_encoder", "clip.has_llava_projector", "clip.has_minicpmv_projector",
                 "clip.has_glm_projector":
                legacy = true
                try reader.skipValue(type)
            case _ where Hyperparameter.all.contains(where: key.hasSuffix):
                if let values = try reader.integers(type), values.allSatisfy({ (0...Limits.dimension).contains($0) }) {
                    hyperparameters[key] = values
                }
            default:
                try reader.skipValue(type)
            }
            // Stop once there's nothing more to learn.
            if known(Hyperparameter.all) { break }
        }
        if let architecture = metadata.architecture, !metadata.isProjector {
            /// One count, for the whole model, that isn't 0.
            func single(_ suffix: String) -> Int? {
                guard let values = hyperparameters[architecture + suffix], values.count == 1, values[0] > 0 else {
                    return nil
                }
                return values[0]
            }
            metadata.embeddingLength = single(Hyperparameter.embeddingLength)
            metadata.blockCount = single(Hyperparameter.blockCount).flatMap { $0 <= Limits.layers ? $0 : nil }
            metadata.contextLength = single(Hyperparameter.contextLength)
            metadata.headCount = hyperparameters[architecture + Hyperparameter.headCount]?.filter { $0 > 0 }.min()
            metadata.headCountKV = hyperparameters[architecture + Hyperparameter.headCountKV]
                .flatMap { $0.isEmpty ? nil : $0 }
            metadata.keyLength = single(Hyperparameter.keyLength)
            metadata.valueLength = single(Hyperparameter.valueLength)
        }
        if metadata.isProjector, !legacy, let width = projectionWidth, width > 0 {
            metadata.imageWidth = width
        }
        return metadata
    }
}

/// The model hyperparameters the reader keeps, by what their keys end with
/// after the architecture's name.
enum Hyperparameter {
    static let embeddingLength = ".embedding_length"
    static let blockCount = ".block_count"
    static let contextLength = ".context_length"
    static let headCount = ".attention.head_count"
    static let headCountKV = ".attention.head_count_kv"
    static let keyLength = ".attention.key_length"
    static let valueLength = ".attention.value_length"

    static let all = [embeddingLength, blockCount, contextLength, headCount, headCountKV, keyLength, valueLength]
    /// Those llama.cpp's converter always writes. It writes the others only
    /// when they differ from what llama.cpp works out without them.
    static let always = [embeddingLength, blockCount, contextLength, headCount]
}

// MARK: Reading

/// Where the reader's bytes come from: a file, or bytes in memory for tests.
protocol GGUFSource {
    mutating func read(upTo count: Int) throws(GGUFError) -> [UInt8]
    mutating func seek(to offset: UInt64) throws(GGUFError)
}

extension FileHandle: GGUFSource {
    func read(upTo count: Int) throws(GGUFError) -> [UInt8] {
        do {
            return try read(upToCount: count).map { [UInt8]($0) } ?? []
        } catch {
            throw .unreadable("it can't be read")
        }
    }

    func seek(to offset: UInt64) throws(GGUFError) {
        do {
            try seek(toOffset: offset)
        } catch {
            throw .unreadable("it can't be read")
        }
    }
}

struct DataSource: GGUFSource {
    let data: Data
    var offset = 0

    mutating func read(upTo count: Int) throws(GGUFError) -> [UInt8] {
        let end = min(data.count, offset + count)
        defer { offset = end }
        return [UInt8](data[data.startIndex + offset ..< data.startIndex + end])
    }

    mutating func seek(to offset: UInt64) throws(GGUFError) {
        self.offset = Int(min(offset, UInt64(data.count)))
    }
}

/// Reads a GGUF header front to back through a buffer, skipping what it
/// doesn't need without building it. Every length is checked against what's
/// left of the file and of `Limits.headerBytes` before anything is read or
/// skipped, so a damaged file fails instead of allocating or looping.
struct GGUFReader {
    var source: any GGUFSource
    let size: UInt64
    /// What's been read from the source and not yet consumed: the bytes from
    /// `start`, of which `cursor` are consumed. The source is at
    /// `start + buffer.count`.
    private var buffer: [UInt8] = []
    private var start: UInt64 = 0
    private var cursor = 0
    private static let chunk = 1 << 16

    init(source: any GGUFSource, size: UInt64) {
        self.source = source
        self.size = size
    }

    var offset: UInt64 { start + UInt64(cursor) }

    /// Fails unless `count` more bytes are in the file and the header limit.
    private func check(_ count: UInt64) throws(GGUFError) {
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, end <= size else { throw .truncated }
        guard end <= GGUFMetadata.Limits.headerBytes else { throw .tooLarge }
    }

    mutating func bytes(_ count: Int) throws(GGUFError) -> ArraySlice<UInt8> {
        try check(UInt64(count))
        if buffer.count - cursor < count {
            buffer.removeFirst(cursor)
            start += UInt64(cursor)
            cursor = 0
            while buffer.count < count {
                let more = try source.read(upTo: max(Self.chunk, count - buffer.count))
                guard !more.isEmpty else { throw .truncated }
                buffer += more
            }
        }
        defer { cursor += count }
        return buffer[cursor ..< cursor + count]
    }

    mutating func skip(_ count: UInt64) throws(GGUFError) {
        try check(count)
        let buffered = UInt64(buffer.count - cursor)
        if count <= buffered {
            cursor += Int(count)
        } else {
            start = offset + count
            buffer = []
            cursor = 0
            try source.seek(to: start)
        }
    }

    private mutating func little<T: FixedWidthInteger>(_: T.Type) throws(GGUFError) -> T {
        let bytes = try self.bytes(MemoryLayout<T>.size)
        return bytes.reversed().reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
    }

    mutating func u32() throws(GGUFError) -> UInt32 { try little(UInt32.self) }
    mutating func u64() throws(GGUFError) -> UInt64 { try little(UInt64.self) }

    // GGUF's value types.
    static let string: UInt32 = 8
    static let array: UInt32 = 9
    static let bool: UInt32 = 7

    /// The size of a value of a fixed-size type, or nil for a string, an
    /// array or a type GGUF doesn't have.
    static func fixedSize(_ type: UInt32) -> UInt64? {
        switch type {
        case 0, 1, 7: 1 // uint8, int8, bool
        case 2, 3: 2 // uint16, int16
        case 4, 5, 6: 4 // uint32, int32, float32
        case 10, 11, 12: 8 // uint64, int64, float64
        default: nil
        }
    }

    /// Skips a value of any type.
    mutating func skipValue(_ type: UInt32) throws(GGUFError) {
        if let size = Self.fixedSize(type) {
            try skip(size)
        } else if type == Self.string {
            try skip(try u64())
        } else if type == Self.array {
            try skipArray(element: try u32(), count: try u64())
        } else {
            throw .corrupt("a value of unknown type \(type)")
        }
    }

    /// Skips an array's elements, once its element type and count are read.
    mutating func skipArray(element: UInt32, count: UInt64) throws(GGUFError) {
        if let size = Self.fixedSize(element) {
            let (total, overflow) = count.multipliedReportingOverflow(by: size)
            guard !overflow else { throw .truncated }
            try skip(total)
        } else if element == Self.string {
            // Each string is at least its 8-byte length: a count the file
            // can't hold fails here, not after a long loop.
            let (least, overflow) = count.multipliedReportingOverflow(by: 8)
            guard !overflow else { throw .truncated }
            try check(least)
            for _ in 0..<count { try skip(try u64()) }
        } else if element == Self.array {
            // llama.cpp doesn't read arrays of arrays either.
            throw .corrupt("an array of arrays")
        } else {
            throw .corrupt("an array of unknown type \(element)")
        }
    }

    /// A string value, or nil when the value is another type or too long to
    /// keep. Either way it's consumed.
    mutating func string(_ type: UInt32) throws(GGUFError) -> String? {
        guard type == Self.string else {
            try skipValue(type)
            return nil
        }
        let length = try u64()
        guard length <= GGUFMetadata.Limits.keptString else {
            try skip(length)
            return nil
        }
        return String(decoding: try bytes(Int(length)), as: UTF8.self)
    }

    /// A whole number of any integer type, or nil when the value is another
    /// type or out of range. Either way it's consumed.
    mutating func integer(_ type: UInt32) throws(GGUFError) -> Int? {
        switch type {
        case 0: return Int(try little(UInt8.self))
        case 1: return Int(try little(Int8.self))
        case 2: return Int(try little(UInt16.self))
        case 3: return Int(try little(Int16.self))
        case 4: return Int(try little(UInt32.self))
        case 5: return Int(try little(Int32.self))
        case 10: return Int(exactly: try little(UInt64.self))
        case 11: return Int(try little(Int64.self))
        default:
            try skipValue(type)
            return nil
        }
    }

    /// A whole number, or an array of them no longer than `Limits.layers`:
    /// one for each layer. Nil when the value is another type, has a number
    /// out of range, or is too long to keep. Either way it's consumed.
    mutating func integers(_ type: UInt32) throws(GGUFError) -> [Int]? {
        guard type == Self.array else { return try integer(type).map { [$0] } }
        let element = try u32()
        let count = try u64()
        guard count <= GGUFMetadata.Limits.layers, let size = Self.fixedSize(element) else {
            try skipArray(element: element, count: count)
            return nil
        }
        // The whole array is in the file before any of it is read.
        try check(count * size)
        var values: [Int] = []
        var whole = true
        for _ in 0..<count {
            if let value = try integer(element) { values.append(value) } else { whole = false }
        }
        return whole ? values : nil
    }

    /// A boolean value, or nil when the value is another type.
    mutating func bool(_ type: UInt32) throws(GGUFError) -> Bool? {
        guard type == Self.bool else {
            try skipValue(type)
            return nil
        }
        return try little(UInt8.self) != 0
    }
}

// MARK: Cache

extension GGUFMetadata {
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date?
    }

    private static let cache = Mutex<[String: (Stamp, Result<GGUFMetadata, GGUFError>)]>([:])

    /// What `read(from:)` returns for the file at `url`, read again only
    /// when the file's size or modification date has changed. The iPad lists
    /// its files often.
    public static func cached(_ url: URL) -> Result<GGUFMetadata, GGUFError> {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .failure(.unreadable("it isn't there"))
        }
        let stamp = Stamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                          modified: attributes[.modificationDate] as? Date)
        if let (seen, result) = cache.withLock({ $0[path] }), seen == stamp { return result }
        let result = Result { () throws(GGUFError) in try read(from: url) }
        cache.withLock { entries in
            // Files come and go: keep the cache from growing without end.
            if entries.count >= 512 { entries.removeAll() }
            entries[path] = (stamp, result)
        }
        return result
    }
}
