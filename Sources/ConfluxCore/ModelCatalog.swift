import Foundation

/// conflux's suggestions for a model it knows: its context per slot, and
/// slots and image tokens where measurements say, and the work it can be
/// trusted with. Applied when the model is first chosen, and the owner can
/// change any of it after (docs/running.md, Defaults for known models).
///
/// A model is known by what its file's header says, its architecture and
/// size, not its file name: any quantization from any publisher matches.
public struct ModelDefaults: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// What people call it, such as "Gemma 4 31B".
    public let name: String
    /// `general.architecture`, `general.size_label` and, where the
    /// architecture is shared by many models, `general.basename`.
    public let architecture: String
    public let sizeLabel: String
    public let basename: String?
    public let contextPerSlot: Int
    /// Nil leaves the owner's.
    public let slots: Int?
    /// Nil is the model's own setting.
    public let imageMinTokens: Int?
    public let labels: ModelLabels
    /// Why: what the suggestion rests on.
    public let basis: String

    public func matches(_ metadata: GGUFMetadata) -> Bool {
        metadata.architecture == architecture
            && metadata.sizeLabel?.lowercased() == sizeLabel.lowercased()
            && (basename.map { metadata.basename?.lowercased() == $0.lowercased() } ?? true)
    }

    /// The model's settings with these.
    public func apply(to config: ModelConfig) -> ModelConfig {
        var config = config
        config.contextPerSlot = contextPerSlot
        if let slots { config.slots = slots }
        config.imageMinTokens = imageMinTokens
        return config
    }

    /// In a line, as `conflux serve` says it.
    public var summary: String {
        var parts = ["\(contextPerSlot.formatted()) tokens per slot"]
        if let slots { parts.append("\(slots) slot\(slots == 1 ? "" : "s")") }
        if let imageMinTokens { parts.append("at least \(imageMinTokens.formatted()) tokens per image") }
        parts.append(labels.tags.isEmpty ? "no tags" : "tagged \(labels.tags.joined(separator: ", "))")
        if labels.onlyWhenAsked { parts.append("only when asked for") }
        return parts.joined(separator: ", ")
    }
}

public enum ModelCatalog {
    /// The models conflux has measured or seen used, in the README's order.
    /// Change one here, and the README's table with it: a test holds them
    /// together.
    public static let entries: [ModelDefaults] = [
        ModelDefaults(
            name: "Qwen3-VL 8B", architecture: "qwen3vl", sizeLabel: "8B", basename: nil,
            contextPerSlot: 8192, slots: nil, imageMinTokens: 1024,
            labels: ModelLabels(tags: ["image-description"]),
            basis: "Reads text in images best of these. Reads images badly with fewer than 1,024 tokens each, "
                + "and one image at that, a prompt and an answer fit in 8,192."),
        ModelDefaults(
            name: "Qwen3-VL 4B", architecture: "qwen3vl", sizeLabel: "4B", basename: nil,
            contextPerSlot: 8192, slots: nil, imageMinTokens: 1024,
            labels: ModelLabels(tags: ["image-description"]),
            basis: "The model in docs/measurements.md, which passed the self-check on every Mac and iPad there. "
                + "Needs 1,024 tokens an image, as the 8B does."),
        ModelDefaults(
            name: "Gemma 3 4B", architecture: "gemma3", sizeLabel: "4B", basename: nil,
            contextPerSlot: 8192, slots: nil, imageMinTokens: nil,
            labels: ModelLabels(tags: ["image-description"]),
            basis: "Describes images quickly, at 256 tokens each (docs/measurements.md, M4 Pro). Most of its "
                + "layers look back only 1,024 tokens, so more context costs it little memory."),
        ModelDefaults(
            name: "Gemma 4 26B-A4B", architecture: "gemma4", sizeLabel: "128x2.6B", basename: nil,
            contextPerSlot: 32768, slots: 1, imageMinTokens: nil,
            labels: ModelLabels(tags: ["image-description"]),
            basis: "Described the benchmark images correctly at nearly a 4B model's speed, and a second slot "
                + "added 9% (docs/measurements.md, M4 Pro). Its context costs little memory: 32,768 tokens "
                + "take under 1 GB."),
        ModelDefaults(
            name: "Gemma 4 31B", architecture: "gemma4", sizeLabel: "31B", basename: nil,
            contextPerSlot: 32768, slots: 1, imageMinTokens: nil,
            labels: ModelLabels(tags: ["editorial", "writing"], onlyWhenAsked: true),
            basis: "Chose among hundreds of items, and wrote, where smaller models fell short, in testing with "
                + "real work. About 20 s a request, and a second slot added nothing (docs/measurements.md, "
                + "M4 Pro), so it's held back for the requests that ask for it."),
        ModelDefaults(
            name: "SmolVLM 256M (the starter model)", architecture: "llama", sizeLabel: "256M", basename: "SmolVLM",
            contextPerSlot: 4096, slots: nil, imageMinTokens: nil,
            labels: ModelLabels(),
            basis: "Proves the plumbing, not the answers (docs/running.md, The starter model), so it's trusted "
                + "with nothing."),
    ]

    public static func defaults(for metadata: GGUFMetadata) -> ModelDefaults? {
        entries.first { $0.matches(metadata) }
    }

    /// For the model file at `path`, from its header. Nil for a file that
    /// can't be read, or a model conflux doesn't know.
    public static func defaults(forModelAt path: String) -> ModelDefaults? {
        guard !path.isEmpty, case .success(let metadata) = GGUFMetadata.cached(URL(fileURLWithPath: path))
        else { return nil }
        return defaults(for: metadata)
    }
}
