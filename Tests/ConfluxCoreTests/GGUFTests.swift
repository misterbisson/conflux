import Foundation
import Testing
@testable import ConfluxCore

/// Writes GGUF headers for the tests: no tensors, and no real model's
/// metadata.
struct GGUFWriter {
    enum Value {
        case string(String)
        case u32(UInt32)
        case u64(UInt64)
        case i32(Int32)
        case f32(Float)
        case bool(Bool)
        case strings([String])
        case floats([Float])
        /// A type and bytes as they are, for damaged files.
        case raw(type: UInt32, bytes: [UInt8])
    }

    var magic = Array("GGUF".utf8)
    var version: UInt32 = 3
    var tensors: UInt64 = 0
    /// The key count written, when it isn't the number of pairs.
    var keyCount: UInt64?
    var pairs: [(String, Value)] = []

    var data: Data {
        var bytes = magic
        bytes += le(version)
        bytes += le(tensors)
        bytes += le(keyCount ?? UInt64(pairs.count))
        for (key, value) in pairs {
            bytes += string(key)
            switch value {
            case .string(let s): bytes += le(UInt32(8)) + string(s)
            case .u32(let n): bytes += le(UInt32(4)) + le(n)
            case .u64(let n): bytes += le(UInt32(10)) + le(n)
            case .i32(let n): bytes += le(UInt32(5)) + le(UInt32(bitPattern: n))
            case .f32(let f): bytes += le(UInt32(6)) + le(f.bitPattern)
            case .bool(let b): bytes += le(UInt32(7)) + [b ? 1 : 0]
            case .strings(let list):
                bytes += le(UInt32(9)) + le(UInt32(8)) + le(UInt64(list.count))
                for s in list { bytes += string(s) }
            case .floats(let list):
                bytes += le(UInt32(9)) + le(UInt32(6)) + le(UInt64(list.count))
                for f in list { bytes += le(f.bitPattern) }
            case .raw(let type, let raw): bytes += le(type) + raw
            }
        }
        return Data(bytes)
    }

    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    func string(_ s: String) -> [UInt8] { le(UInt64(s.utf8.count)) + Array(s.utf8) }

    /// A text model, its tokenizer between its names and its width, so the
    /// reader has to skip it.
    static func model(arch: String = "llama", name: String = "Example 1B", basename: String = "Example",
                      width: UInt32 = 2048, tokens: Int = 1000, version: UInt32 = 3) -> GGUFWriter {
        GGUFWriter(version: version, tensors: 201, pairs: [
            ("general.architecture", .string(arch)),
            ("general.type", .string("model")),
            ("general.name", .string(name)),
            ("tokenizer.ggml.tokens", .strings((0..<tokens).map { "token\($0)" })),
            ("tokenizer.ggml.scores", .floats((0..<tokens).map(Float.init))),
            ("\(arch).context_length", .u32(8192)),
            ("\(arch).embedding_length", .u32(width)),
            ("general.basename", .string(basename)),
            ("tokenizer.chat_template", .string(String(repeating: "{{ x }}", count: 2000))),
        ])
    }

    /// A projector in the form llama.cpp's converter writes.
    static func projector(name: String = "Example 1B", basename: String = "Example", width: UInt32 = 2048,
                          vision: Bool = true, audio: Bool = false, version: UInt32 = 3) -> GGUFWriter {
        var pairs: [(String, Value)] = [
            ("general.architecture", .string("clip")),
            ("general.type", .string("mmproj")),
            ("general.name", .string(name)),
            ("general.basename", .string(basename)),
            ("clip.projector_type", .string("idefics3")),
        ]
        if vision {
            pairs += [("clip.has_vision_encoder", .bool(true)),
                      ("clip.vision.projection_dim", .u32(width)),
                      ("clip.vision.embedding_length", .u32(768)),
                      ("clip.vision.image_mean", .floats([0.5, 0.5, 0.5]))]
        }
        if audio {
            pairs += [("clip.has_audio_encoder", .bool(true)),
                      ("clip.audio.projection_dim", .u32(width))]
        }
        return GGUFWriter(version: version, tensors: 12, pairs: pairs)
    }
}

@Suite struct GGUFReaderTests {
    @Test(arguments: [UInt32(2), 3]) func readsAModel(version: UInt32) throws {
        let metadata = try GGUFMetadata.read(from: GGUFWriter.model(version: version).data)
        #expect(metadata == GGUFMetadata(version: version, architecture: "llama", name: "Example 1B",
                                         basename: "Example", embeddingLength: 2048))
        #expect(!metadata.isProjector)
    }

    @Test(arguments: [UInt32(2), 3]) func readsAProjector(version: UInt32) throws {
        let metadata = try GGUFMetadata.read(from: GGUFWriter.projector(width: 3584, version: version).data)
        #expect(metadata.isProjector)
        #expect(metadata.readsImages)
        #expect(metadata.imageWidth == 3584)
        // The image encoder's own width isn't the model's.
        #expect(metadata.embeddingLength == nil)
        #expect(metadata.basename == "Example")
    }

    @Test func skipsALargeTokenizerWithoutBuildingIt() throws {
        // About the size of a real tokenizer.
        let data = GGUFWriter.model(tokens: 150_000).data
        let started = ContinuousClock.now
        let metadata = try GGUFMetadata.read(from: data)
        #expect(metadata.embeddingLength == 2048)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func readsTheModelsWidthWhateverIntegerTypeItIs() throws {
        var writer = GGUFWriter.model()
        writer.pairs = writer.pairs.map { $0.0 == "llama.embedding_length" ? ($0.0, .u64(4096)) : $0 }
        #expect(try GGUFMetadata.read(from: writer.data).embeddingLength == 4096)
        writer.pairs = writer.pairs.map { $0.0 == "llama.embedding_length" ? ($0.0, .i32(-1)) : $0 }
        #expect(try GGUFMetadata.read(from: writer.data).embeddingLength == nil)
        writer.pairs = writer.pairs.map { $0.0 == "llama.embedding_length" ? ($0.0, .string("2048")) : $0 }
        #expect(try GGUFMetadata.read(from: writer.data).embeddingLength == nil)
    }

    @Test func takesOnlyTheArchitecturesOwnWidth() throws {
        var writer = GGUFWriter.model(arch: "qwen2vl")
        writer.pairs.insert(("llama.embedding_length", .u32(999)), at: 1)
        #expect(try GGUFMetadata.read(from: writer.data).embeddingLength == 2048)
    }

    @Test func distrustsTheWidthOlderConvertersWrote() throws {
        // llama.cpp's legacy llava converter wrote CLIP's own projection
        // width, not the model's.
        var writer = GGUFWriter.projector(width: 768)
        writer.pairs += [("clip.has_text_encoder", .bool(false)), ("clip.has_llava_projector", .bool(true))]
        let metadata = try GGUFMetadata.read(from: writer.data)
        #expect(metadata.isProjector)
        #expect(metadata.readsImages)
        #expect(metadata.imageWidth == nil)
        #expect(try GGUFMetadata.read(from: GGUFWriter.projector(width: 0).data).imageWidth == nil)
    }

    @Test func tellsAnAudioProjectorFromAnImageOne() throws {
        let audio = try GGUFMetadata.read(from: GGUFWriter.projector(vision: false, audio: true).data)
        #expect(audio.isProjector)
        #expect(!audio.readsImages)
        #expect(audio.imageWidth == nil)
        let both = try GGUFMetadata.read(from: GGUFWriter.projector(vision: true, audio: true).data)
        #expect(both.readsImages)
    }

    @Test func refusesAFileThatIsntGGUF() {
        var writer = GGUFWriter.model()
        writer.magic = Array("GGML".utf8)
        #expect(throws: GGUFError.notGGUF) { try GGUFMetadata.read(from: writer.data) }
        #expect(throws: GGUFError.notGGUF) { try GGUFMetadata.read(from: Data()) }
        #expect(throws: GGUFError.notGGUF) { try GGUFMetadata.read(from: Data("{\"not\": \"gguf\"}".utf8)) }
    }

    @Test(arguments: [UInt32(0), 1, 4, 0x0300_0000]) func refusesOtherVersions(version: UInt32) {
        // 0x03000000 is version 3 written big-endian.
        #expect(throws: GGUFError.unsupportedVersion(version)) {
            try GGUFMetadata.read(from: GGUFWriter.model(version: version).data)
        }
    }

    @Test func failsCleanlyWhereverAFileIsCut() {
        let data = GGUFWriter.projector().data
        for length in 1..<data.count {
            #expect(throws: GGUFError.truncated) { try GGUFMetadata.read(from: data.prefix(length)) }
        }
    }

    @Test func refusesAbsurdCounts() {
        var writer = GGUFWriter.model()
        writer.keyCount = .max
        #expect(throws: GGUFError.corrupt("it claims \(UInt64.max) keys")) { try GGUFMetadata.read(from: writer.data) }
        writer = GGUFWriter.model()
        writer.tensors = 1 << 40
        #expect(throws: GGUFError.corrupt("it claims \(1 << 40) tensors")) {
            try GGUFMetadata.read(from: writer.data)
        }
        // More keys than there are, within the limit: the file runs out.
        writer = GGUFWriter.projector()
        writer.keyCount = 1000
        #expect(throws: GGUFError.truncated) { try GGUFMetadata.read(from: writer.data) }
    }

    @Test func refusesAbsurdLengths() {
        let w = GGUFWriter()
        func damaged(_ value: GGUFWriter.Value) -> Data {
            GGUFWriter(pairs: [("general.architecture", .string("llama")), ("bad", value)]).data
        }
        // A string as long as there are bytes in an exabyte.
        #expect(throws: GGUFError.truncated) {
            try GGUFMetadata.read(from: damaged(.raw(type: 8, bytes: w.le(UInt64(1) << 60))))
        }
        // A wanted string the same.
        #expect(throws: GGUFError.truncated) {
            try GGUFMetadata.read(from: GGUFWriter(pairs: [
                ("general.name", .raw(type: 8, bytes: w.le(UInt64.max)))]).data)
        }
        // Arrays whose size overflows, or that the file can't hold.
        #expect(throws: GGUFError.truncated) {
            try GGUFMetadata.read(from: damaged(.raw(type: 9, bytes: w.le(UInt32(10)) + w.le(UInt64.max))))
        }
        #expect(throws: GGUFError.truncated) {
            try GGUFMetadata.read(from: damaged(.raw(type: 9, bytes: w.le(UInt32(8)) + w.le(UInt64(1) << 61))))
        }
        #expect(throws: GGUFError.truncated) {
            try GGUFMetadata.read(from: damaged(.raw(type: 9, bytes: w.le(UInt32(8)) + w.le(UInt64.max))))
        }
        // A key longer than any key.
        var long = GGUFWriter()
        long.keyCount = 1
        #expect(throws: GGUFError.corrupt("a key \(UInt64(1) << 50) bytes long")) {
            try GGUFMetadata.read(from: long.data + Data(w.le(UInt64(1) << 50)))
        }
    }

    @Test func refusesTypesLlamaCppDoesnt() {
        let w = GGUFWriter()
        func damaged(_ value: GGUFWriter.Value) -> Data { GGUFWriter(pairs: [("bad", value)]).data }
        #expect(throws: GGUFError.corrupt("a value of unknown type 99")) {
            try GGUFMetadata.read(from: damaged(.raw(type: 99, bytes: [])))
        }
        #expect(throws: GGUFError.corrupt("an array of arrays")) {
            try GGUFMetadata.read(from: damaged(.raw(type: 9, bytes: w.le(UInt32(9)) + w.le(UInt64(1)))))
        }
        #expect(throws: GGUFError.corrupt("an array of unknown type 13")) {
            try GGUFMetadata.read(from: damaged(.raw(type: 9, bytes: w.le(UInt32(13)) + w.le(UInt64(1)))))
        }
    }

    @Test func stopsAtTheHeaderLimit() throws {
        // A file that claims to be huge: the reader stops before reading past
        // the limit, without reading up to it.
        var reader = GGUFReader(source: DataSource(data: Data(count: 64)), size: 1 << 40)
        #expect(throws: GGUFError.tooLarge) { try reader.skip(GGUFMetadata.Limits.headerBytes + 1) }
    }

    @Test func readsAFileOnDiskAndRereadsItOnlyWhenItChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conflux-gguf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "renamed.gguf")

        try GGUFWriter.projector(width: 2048).data.write(to: url)
        #expect(try GGUFMetadata.read(from: url).imageWidth == 2048)
        #expect(try GGUFMetadata.cached(url).get().imageWidth == 2048)

        // Another file under the same name, of another size.
        try GGUFWriter.model(width: 896).data.write(to: url)
        #expect(try GGUFMetadata.cached(url).get().embeddingLength == 896)
        try Data("not a model".utf8).write(to: url)
        #expect(GGUFMetadata.cached(url) == .failure(.notGGUF))

        let missing = directory.appending(path: "missing.gguf")
        #expect(throws: GGUFError.self) { try GGUFMetadata.read(from: missing) }
        #expect((try? GGUFMetadata.cached(missing).get()) == nil)
    }
}

@Suite struct ProjectorTests {
    func file(_ name: String, _ writer: GGUFWriter) -> GGUFFile {
        GGUFFile(url: URL(fileURLWithPath: "/models/\(name)"),
                 metadata: Result { () throws(GGUFError) in try GGUFMetadata.read(from: writer.data) })
    }

    func unreadable(_ name: String) -> GGUFFile {
        GGUFFile(url: URL(fileURLWithPath: "/models/\(name)"), metadata: .failure(.truncated))
    }

    // Two vision models of different widths, and their projectors.
    var small: GGUFFile { file("Small-VL-2B-Q4_K_M.gguf", .model(name: "Small VL 2B", basename: "Small-VL", width: 2048)) }
    var large: GGUFFile { file("Large-VL-7B-Q4_K_M.gguf", .model(name: "Large VL 7B", basename: "Large-VL", width: 3584)) }
    var smallProjector: GGUFFile {
        file("mmproj-Small-VL-2B-f16.gguf", .projector(name: "Small VL 2B", basename: "Small-VL", width: 2048))
    }
    var largeProjector: GGUFFile {
        file("mmproj-Large-VL-7B-f16.gguf", .projector(name: "Large VL 7B", basename: "Large-VL", width: 3584))
    }

    @Test func tellsAProjectorByItsHeaderNotItsName() {
        #expect(file("vision.gguf", .projector()).isProjector)
        #expect(!file("mmproj-but-a-model.gguf", .model()).isProjector)
        // Only an unreadable file goes by its name.
        #expect(unreadable("mmproj-something.gguf").isProjector)
        #expect(!unreadable("something.gguf").isProjector)
    }

    @Test func suggestsEachModelItsOwnProjector() {
        let projectors = [largeProjector, smallProjector]
        #expect(Projectors.suggestion(for: small, among: projectors) == smallProjector.url)
        #expect(Projectors.suggestion(for: large, among: projectors) == largeProjector.url)
    }

    @Test func suggestsARenamedProjectorThatFits() {
        let renamed = file("vision.gguf", .projector(name: "Small VL 2B", basename: "Small-VL", width: 2048))
        #expect(Projectors.suggestion(for: small, among: [renamed, largeProjector]) == renamed.url)
    }

    @Test func suggestsNoneWhenNoneFits() {
        #expect(Projectors.suggestion(for: small, among: [largeProjector]) == nil)
        // Nor one whose width can't be known, nor an unreadable one.
        var legacy = GGUFWriter.projector(width: 2048)
        legacy.pairs.append(("clip.has_llava_projector", .bool(true)))
        #expect(Projectors.suggestion(for: small, among: [file("mmproj-legacy.gguf", legacy),
                                                          unreadable("mmproj-Small-VL-2B-f16.gguf")]) == nil)
        // Nor for a model that can't be read.
        #expect(Projectors.suggestion(for: unreadable("Small-VL-2B.gguf"), among: [smallProjector]) == nil)
        // Nor an audio projector.
        let audio = file("mmproj-audio.gguf", .projector(width: 2048, vision: false, audio: true))
        #expect(Projectors.suggestion(for: small, among: [audio]) == nil)
    }

    @Test func breaksTiesByName() {
        // Another model as wide as the small one, with its own projector.
        let other = file("Other-3B-Q8_0.gguf", .model(name: "Other 3B", basename: "Other", width: 2048))
        let otherProjector = file("mmproj-Other-3B-f16.gguf", .projector(name: "Other 3B", basename: "Other",
                                                                         width: 2048))
        let projectors = [otherProjector, smallProjector, largeProjector]
        #expect(Projectors.suggestion(for: small, among: projectors) == smallProjector.url)
        #expect(Projectors.suggestion(for: other, among: projectors) == otherProjector.url)

        // Without names in either header, by file name.
        let a = file("Alpha-Q4.gguf", .model(name: "", basename: "", width: 1024))
        let alpha = file("mmproj-Alpha-f16.gguf", .projector(name: "", basename: "", width: 1024))
        let beta = file("mmproj-Beta-f16.gguf", .projector(name: "", basename: "", width: 1024))
        #expect(Projectors.suggestion(for: a, among: [beta, alpha]) == alpha.url)

        // Names that don't tell them apart: none.
        let twin = file("twin.gguf", .projector(name: "", basename: "", width: 1024))
        let twin2 = file("twin2.gguf", .projector(name: "", basename: "", width: 1024))
        #expect(Projectors.suggestion(for: file("x.gguf", .model(name: "", basename: "", width: 1024)),
                                      among: [twin, twin2]) == nil)
    }

    @Test func saysWhatsWrongWithAPair() {
        #expect(Projectors.problems(model: small, projector: smallProjector).isEmpty)
        #expect(Projectors.problems(model: small, projector: nil).isEmpty)
        #expect(Projectors.problems(model: nil, projector: nil).isEmpty)

        let swapped = Projectors.problems(model: smallProjector, projector: small)
        #expect(swapped.count == 2)
        #expect(swapped[0].contains("is a projector, not a model"))
        #expect(swapped[1].contains("is a model, not a projector"))

        let wrong = Projectors.problems(model: small, projector: largeProjector)
        #expect(wrong == ["mmproj-Large-VL-7B-f16.gguf was made for another model: it gives the model vectors 3584 "
            + "wide, and Small-VL-2B-Q4_K_M.gguf takes 2048. Choose the projector made for this model."])

        let audio = file("audio.gguf", .projector(vision: false, audio: true))
        #expect(Projectors.problems(model: small, projector: audio).first?.contains("reads audio, not images") == true)

        #expect(Projectors.problems(model: unreadable("broken.gguf"), projector: nil)
            == ["conflux can't read broken.gguf: it ends partway through its header, so it's incomplete."])

        // A width that can't be known isn't called wrong.
        var legacy = GGUFWriter.projector(width: 768)
        legacy.pairs.append(("clip.has_llava_projector", .bool(true)))
        #expect(Projectors.problems(model: small, projector: file("mmproj-legacy.gguf", legacy)).isEmpty)
    }
}

/// The starter model's two files, when ci_scripts/ci_post_clone.sh has
/// fetched them. Skipped otherwise: nothing committed depends on them.
@Suite struct StarterModelHeaderTests {
    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "App/StarterModel")
    }

    static var present: Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: StarterModel.modelFile).path)
    }

    @Test(.enabled(if: present)) func starterModelAndProjectorMatch() throws {
        let model = GGUFFile(Self.folder.appending(path: StarterModel.modelFile))
        let projector = GGUFFile(Self.folder.appending(path: StarterModel.projectorFile))
        #expect(!model.isProjector)
        #expect(projector.isProjector)
        #expect(Projectors.suggestion(for: model, among: [projector]) == projector.url)
        #expect(Projectors.problems(model: model, projector: projector).isEmpty)
    }
}
