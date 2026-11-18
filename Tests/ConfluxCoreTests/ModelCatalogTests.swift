import Foundation
import Testing
@testable import ConfluxCore

/// conflux's suggestions for the models it knows (`ModelCatalog`).
@Suite struct ModelCatalogTests {
    func metadata(_ architecture: String, _ sizeLabel: String?, basename: String? = nil) -> GGUFMetadata {
        var metadata = GGUFMetadata(architecture: architecture, basename: basename)
        metadata.sizeLabel = sizeLabel
        return metadata
    }

    /// What these models' files say, read from the files the README points at.
    @Test func knowsTheModelsTheReadmeSuggests() {
        let names = [
            metadata("qwen3vl", "8B", basename: "qwen3vl"), metadata("qwen3vl", "4B", basename: "qwen3vl"),
            metadata("gemma3", "4B", basename: "gemma-3"), metadata("gemma4", "128x2.6B"),
            metadata("gemma4", "31B"), metadata("llama", "256M", basename: "SmolVLM"),
        ].map { ModelCatalog.defaults(for: $0)?.name }
        #expect(names == ModelCatalog.entries.map(\.name))
    }

    @Test func aModelItDoesntKnowHasNoSuggestions() {
        #expect(ModelCatalog.defaults(for: metadata("gemma4", "E4B")) == nil)
        #expect(ModelCatalog.defaults(for: metadata("gemma3", nil)) == nil)
        // The starter model's architecture is shared: only SmolVLM matches.
        #expect(ModelCatalog.defaults(for: metadata("llama", "256M", basename: "Other")) == nil)
        #expect(ModelCatalog.defaults(for: metadata("llama", "256M", basename: "smolvlm")) != nil)
    }

    @Test func theLargeModelIsHeldBackForTheWorkItDoes() throws {
        let large = try #require(ModelCatalog.defaults(for: metadata("gemma4", "31B")))
        #expect(large.labels == ModelLabels(tags: ["editorial", "writing"], onlyWhenAsked: true))
        #expect(large.contextPerSlot == 32768)
        #expect(large.slots == 1)
    }

    @Test func everySuggestionIsSound() {
        for entry in ModelCatalog.entries {
            #expect(ModelConfig.contextSizes.contains(entry.contextPerSlot), "\(entry.name)")
            #expect(entry.labels.tags.allSatisfy(ModelTag.isDocumented), "\(entry.name)")
            #expect(!entry.basis.isEmpty)
        }
    }

    @Test func suggestionsReplaceTheModelsSettings() throws {
        let qwen = try #require(ModelCatalog.defaults(for: metadata("qwen3vl", "8B")))
        let gemma = try #require(ModelCatalog.defaults(for: metadata("gemma4", "31B")))
        let before = ModelConfig(model: "/m.gguf", slots: 3, contextPerSlot: 2048, imageMinTokens: 512)
        let asQwen = qwen.apply(to: before)
        #expect(asQwen.contextPerSlot == 8192)
        #expect(asQwen.slots == 3)
        #expect(asQwen.imageMinTokens == 1024)
        // Another model's image tokens don't follow it.
        let asGemma = gemma.apply(to: asQwen)
        #expect(asGemma.imageMinTokens == nil)
        #expect(asGemma.slots == 1)
    }

    @Test func readsTheSizeLabel() throws {
        let data = GGUFWriter(pairs: [
            ("general.architecture", .string("gemma4")),
            ("general.size_label", .string("31B")),
        ]).data
        let metadata = try GGUFMetadata.read(from: data)
        #expect(metadata.sizeLabel == "31B")
        #expect(ModelCatalog.defaults(for: metadata)?.name == "Gemma 4 31B")
    }

    @Test func aKnownModelFileTakesItsSuggestedLabelsUntilItsOwnerSays() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString).gguf")
        try GGUFWriter(pairs: [
            ("general.architecture", .string("gemma4")),
            ("general.size_label", .string("31B")),
        ]).data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = ModelConfig(model: url.path)
        var settings = NodeSettings()
        #expect(settings.labels(for: config) == ModelLabels(tags: ["editorial", "writing"], onlyWhenAsked: true))
        settings.labels[config.modelID] = ModelLabels(tags: ["reasoning"])
        #expect(settings.labels(for: config) == ModelLabels(tags: ["reasoning"]))
        #expect(settings.labels(for: ModelConfig(model: "/no/such/file.gguf")) == ModelLabels())
    }

    /// The README lists every suggestion, as the catalog has it.
    @Test func theReadmeSaysWhatTheCatalogDoes() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "README.md")
        let rows = try String(contentsOf: readme, encoding: .utf8).split(separator: "\n").map(String.init)
        for entry in ModelCatalog.entries {
            let row = rows.first { $0.hasPrefix("| \(entry.name) |") }
            #expect(row != nil, "no README row for \(entry.name)")
            guard let row else { continue }
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(cells.count >= 4, "\(row)")
            guard cells.count >= 4 else { continue }
            #expect(cells[1] == entry.contextPerSlot.formatted(.number.locale(Locale(identifier: "en_US"))) 
                + (entry.slots.map { ", \($0) slot\($0 == 1 ? "" : "s")" } ?? "")
                + (entry.imageMinTokens.map { ", \($0.formatted(.number.locale(Locale(identifier: "en_US")))) per image" } ?? ""),
                "\(entry.name)")
            let tags = entry.labels.tags.isEmpty ? "none" : entry.labels.tags.map { "`\($0)`" }.joined(separator: ", ")
            #expect(cells[2] == tags, "\(entry.name)")
            #expect(cells[3] == (entry.labels.onlyWhenAsked ? "only when asked for" : "any"), "\(entry.name)")
        }
    }
}
