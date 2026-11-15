import Foundation
import Testing
@testable import ConfluxCore

/// The model chosen on an iPad is found again on its next launch, even where
/// an update moved it.
@Suite struct ChosenFileTests {
    let container = URL(fileURLWithPath: "/containers/A/Documents")
    let moved = URL(fileURLWithPath: "/containers/B/Documents")

    @Test func findsTheSameFile() {
        let model = container.appending(path: "Qwen/model.gguf")
        let other = container.appending(path: "other.gguf")
        #expect(ChosenFile(model).find(in: [other, model]) == model)
    }

    @Test func findsAFileThatMovedWithItsFolder() {
        let chosen = ChosenFile(container.appending(path: "Qwen/model.gguf"))
        let there = moved.appending(path: "Qwen/model.gguf")
        let elsewhere = moved.appending(path: "Gemma/model.gguf")
        #expect(chosen.find(in: [elsewhere, there]) == there)
    }

    @Test func findsAFileByItsNameWhenOnlyOneHasIt() {
        let chosen = ChosenFile(container.appending(path: "model.gguf"))
        let renamedFolder = moved.appending(path: "Kept/model.gguf")
        #expect(chosen.find(in: [renamedFolder]) == renamedFolder)
    }

    @Test func findsNothingWhenTheNameIsAmbiguousOrGone() {
        let chosen = ChosenFile(container.appending(path: "Qwen/model.gguf"))
        let one = moved.appending(path: "Gemma/model.gguf")
        let two = moved.appending(path: "Llama/model.gguf")
        #expect(chosen.find(in: [one, two]) == nil)
        #expect(chosen.find(in: [moved.appending(path: "other.gguf")]) == nil)
    }

    @Test func aChoiceSurvivesEncoding() throws {
        let choice = ChosenModelFile(model: container.appending(path: "model.gguf"), projector: nil, slots: 2,
                                     contextPerSlot: 8192)
        let decoded = try JSONDecoder().decode(ChosenModelFile.self, from: JSONEncoder().encode(choice))
        #expect(decoded == choice)
        #expect(decoded.projector == nil)
    }
}
