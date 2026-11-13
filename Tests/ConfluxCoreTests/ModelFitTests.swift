import Foundation
import Testing
@testable import ConfluxCore

@Suite struct ModelFitTests {
    static let gigabyte: UInt64 = 1 << 30

    func metadata(_ writer: GGUFWriter) throws -> GGUFMetadata { try GGUFMetadata.read(from: writer.data) }

    @Test func worksOutTheContextFromTheHeader() throws {
        // 30 layers of 3 key/value heads, keys and values 64 wide, two bytes
        // each: 23,040 bytes a token.
        let model = try metadata(.transformer(keyWidth: 64, valueWidth: 64))
        #expect(ModelFit.contextBytes(model, tokens: 4096) == 30 * 3 * (64 + 64) * 2 * 4096)
        // Without the widths, the embedding length over the heads: 576 / 9.
        let plain = try metadata(.transformer())
        #expect(ModelFit.contextBytes(plain, tokens: 4096) == 30 * 3 * (64 + 64) * 2 * 4096)
        // Without the key/value heads, as many as the attention heads.
        let full = try metadata(.transformer(kvHeads: nil))
        #expect(ModelFit.contextBytes(full, tokens: 4096) == 30 * 9 * (64 + 64) * 2 * 4096)
        // Rounded up to 256 tokens, as llama.cpp does.
        #expect(ModelFit.contextBytes(plain, tokens: 1000) == ModelFit.contextBytes(plain, tokens: 1024))
    }

    @Test func usesTheWidthsTheHeaderGives() throws {
        // Heads wider than the embedding length over the head count, as some
        // models have: the given width counts.
        let model = try metadata(.transformer(layers: 36, width: 2560, heads: 32, kvHeads: .u32(8), keyWidth: 128,
                                              valueWidth: 128))
        #expect(ModelFit.contextBytes(model, tokens: 4096) == 36 * 8 * (128 + 128) * 2 * 4096)
        let narrowValues = try metadata(.transformer(keyWidth: 192, valueWidth: 128))
        #expect(ModelFit.contextBytes(narrowValues, tokens: 256) == 30 * 3 * (192 + 128) * 2 * 256)
    }

    @Test func countsEachLayersHeads() throws {
        // Layers without attention keep no context.
        let hybrid = try metadata(.transformer(layers: 4, kvHeads: .ints([3, 0, 3, 0])))
        #expect(ModelFit.contextBytes(hybrid, tokens: 256) == 6 * (64 + 64) * 2 * 256)
        // A list that doesn't match the layers: the most in every layer.
        let odd = try metadata(.transformer(layers: 4, kvHeads: .ints([3, 0, 5])))
        #expect(ModelFit.contextBytes(odd, tokens: 256) == 4 * 5 * (64 + 64) * 2 * 256)
    }

    @Test func saysNothingOfAContextTheHeaderDoesntDescribe() throws {
        #expect(ModelFit.contextBytes(GGUFMetadata(architecture: "mamba", embeddingLength: 768), tokens: 4096) == nil)
        #expect(ModelFit.contextBytes(try metadata(.projector()), tokens: 4096) == nil)
        #expect(ModelFit.contextBytes(try metadata(.transformer()), tokens: 0) == nil)

        // Then the estimate is the files and the working room.
        let fit = ModelFit(model: nil, modelBytes: 1_000, projectorBytes: 200, slots: 2, contextPerSlot: 4096)
        #expect(fit.context == nil)
        #expect(fit.total == 1_200 + ModelFit.base + 2 * ModelFit.perSlot)
    }

    @Test func addsTheFilesEachSlotsContextAndRoom() throws {
        let model = try metadata(.transformer())
        let one = ModelFit(model: model, modelBytes: 175_000_000, projectorBytes: 104_000_000, slots: 1,
                           contextPerSlot: 4096)
        let context = try #require(ModelFit.contextBytes(model, tokens: 4096))
        #expect(one.weights == 279_000_000)
        #expect(one.context == context)
        #expect(one.total == 279_000_000 + context + ModelFit.base + ModelFit.perSlot)

        let three = ModelFit(model: model, modelBytes: 175_000_000, projectorBytes: nil, slots: 3,
                             contextPerSlot: 4096)
        #expect(three.context == 3 * context)
        #expect(three.total == 175_000_000 + 3 * context + ModelFit.base + 3 * ModelFit.perSlot)
    }

    @Test func notesMoreContextThanTheModelWasTrainedFor() throws {
        let model = try metadata(.transformer(context: 8192))
        let within = ModelFit(model: model, modelBytes: 1, projectorBytes: nil, slots: 1, contextPerSlot: 8192)
        #expect(within.trainedContext == nil)
        let beyond = ModelFit(model: model, modelBytes: 1, projectorBytes: nil, slots: 1, contextPerSlot: 32768)
        #expect(beyond.trainedContext == 8192)
        // llama.cpp makes the context as large as asked, so it's all counted.
        #expect(beyond.context == ModelFit.contextBytes(model, tokens: 32768))
    }

    @Test func keepsAQuarterBack() {
        let eight = 8 * Self.gigabyte
        #expect(ModelFit.usable(allowed: eight, physicalMemory: eight) == 6 * Self.gigabyte)
        // An allowance larger than the memory is no use.
        #expect(ModelFit.usable(allowed: 16 * Self.gigabyte, physicalMemory: eight) == 6 * Self.gigabyte)
        #expect(ModelFit.usable(allowed: 4 * Self.gigabyte, physicalMemory: eight) == 3 * Self.gigabyte)
        #expect(ModelFit.usable(allowed: eight, physicalMemory: 0) == 6 * Self.gigabyte)
    }

    @Test func saysHowLargeAModelFits() {
        let eight = 8 * Self.gigabyte
        // 6 GB usable, less the room for one slot of a typical context, is
        // 4.75 GB: about 4.5.
        #expect(ModelFit.largestModel(allowed: eight, physicalMemory: eight) == 4 * Self.gigabyte + Self.gigabyte / 2)
        #expect(ModelFit.largestModel(allowed: Self.gigabyte, physicalMemory: eight) == 0)
        #expect(ModelFit.largestModel(allowed: 0, physicalMemory: 0) == 0)
    }

    @Test func marksAModelLikelyTooBig() throws {
        let eight = 8 * Self.gigabyte
        // A 4B model's shape: 36 layers of 8 key/value heads 128 wide.
        let model = try metadata(.transformer(layers: 36, width: 2560, heads: 32, kvHeads: .u32(8), keyWidth: 128,
                                              valueWidth: 128))
        let small = ModelFit(model: model, modelBytes: 2_500_000_000, projectorBytes: 800_000_000, slots: 1,
                             contextPerSlot: 4096)
        #expect(small.likelyFits(allowed: eight, physicalMemory: eight))
        // The same files with four slots of 32,768 tokens: 18 GB of context.
        let greedy = ModelFit(model: model, modelBytes: 2_500_000_000, projectorBytes: 800_000_000, slots: 4,
                              contextPerSlot: 32768)
        #expect(!greedy.likelyFits(allowed: eight, physicalMemory: eight))
        // An 8B model at 8 bits.
        let large = ModelFit(model: model, modelBytes: 8_500_000_000, projectorBytes: nil, slots: 1,
                             contextPerSlot: 4096)
        #expect(!large.likelyFits(allowed: eight, physicalMemory: eight))
    }

    @Test func neverOverflows() {
        let huge = GGUFMetadata(architecture: "llama", embeddingLength: 1 << 24, blockCount: 4096, headCount: 1,
                                headCountKV: [1 << 24])
        let fit = ModelFit(model: huge, modelBytes: .max, projectorBytes: .max, slots: 4, contextPerSlot: 1 << 30)
        #expect(fit.total == .max)
        #expect(!fit.likelyFits(allowed: .max, physicalMemory: .max))
    }
}
