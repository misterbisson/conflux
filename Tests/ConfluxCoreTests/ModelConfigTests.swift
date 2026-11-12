import Testing
@testable import ConfluxCore

@Suite struct ModelConfigChoicesTests {
    @Test func defaultsAreOffered() {
        let defaults = ModelConfig(model: "")
        #expect(ModelConfig.contextSizes.contains(defaults.contextPerSlot))
        #expect(ModelConfig.imageSides.contains(defaults.maxImageDimension))
    }

    @Test func listedValueLeavesTheChoicesAlone() {
        #expect(ModelConfig.choices(ModelConfig.contextSizes, including: 8192) == ModelConfig.contextSizes)
    }

    @Test func unlistedValueIsAddedInOrder() {
        #expect(ModelConfig.choices([1024, 2048, 4096], including: 3072) == [1024, 2048, 3072, 4096])
        #expect(ModelConfig.choices([1024, 2048], including: 256) == [256, 1024, 2048])
        #expect(ModelConfig.choices([1024, 2048], including: 131072) == [1024, 2048, 131072])
    }
}
