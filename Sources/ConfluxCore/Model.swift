import Foundation

/// What a host serves: one model artifact, run by one runtime.
public struct ModelInfo: Sendable, Equatable, Codable {
    /// The artifact's ID, as clients name it in `model` and as responses
    /// report it. For a GGUF file, its name without the extension.
    public var id: String
    public var capabilities: Set<Capability>
    /// Runtime, runtime version, and a hash of the artifact's files.
    public var fingerprint: String
    /// The longest image side worth sending. Larger images cost transfer time
    /// and give the model nothing.
    public var maxImageDimension: Int?
    /// Whether the model's runtime declines some content, as Apple's
    /// on-device model's guardrails do, answering `content_filter`. Clients
    /// that send such content can leave these models out.
    public var contentFilter: Bool
    /// Tokens of context each slot holds, when the host says. Nil from peers
    /// from before it was reported, which no `context-<N>k` request reaches.
    public var contextTokens: Int?
    /// The work the owner trusts the model with (`ModelTag`), sorted. Image
    /// tags only on a model that reads images.
    public var tags: [String]
    /// Whether the owner holds the model back, so it answers only requests
    /// that name it or one of its tags (`ModelChoice.Needs`).
    public var onlyWhenAsked: Bool

    public enum Capability: String, Sendable, Codable, CaseIterable {
        case text, vision
    }

    public init(id: String, capabilities: Set<Capability>, fingerprint: String, maxImageDimension: Int? = nil,
                contentFilter: Bool = false, contextTokens: Int? = nil, tags: [String] = [],
                onlyWhenAsked: Bool = false) {
        self.id = id
        self.capabilities = capabilities
        self.fingerprint = fingerprint
        self.maxImageDimension = maxImageDimension
        self.contentFilter = contentFilter
        self.contextTokens = contextTokens
        self.tags = tags
        self.onlyWhenAsked = onlyWhenAsked
    }

    enum CodingKeys: String, CodingKey {
        case id, capabilities, fingerprint, maxImageDimension, contentFilter, contextTokens, tags, onlyWhenAsked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        capabilities = try container.decode(Set<Capability>.self, forKey: .capabilities)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        maxImageDimension = try container.decodeIfPresent(Int.self, forKey: .maxImageDimension)
        // A peer from before this was reported filters content only if it
        // serves Apple's model.
        contentFilter = try container.decodeIfPresent(Bool.self, forKey: .contentFilter)
            ?? (id == AppleModelHost.modelID)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        // A peer from before tags has none, and holds nothing back.
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        onlyWhenAsked = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenAsked) ?? false
    }

    /// Leaves out tags when there are none, and holding back when it's off,
    /// so a model the owner hasn't labelled reads as it did before them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(maxImageDimension, forKey: .maxImageDimension)
        try container.encode(contentFilter, forKey: .contentFilter)
        try container.encodeIfPresent(contextTokens, forKey: .contextTokens)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        if onlyWhenAsked { try container.encode(onlyWhenAsked, forKey: .onlyWhenAsked) }
    }

    /// The same model, labelled as its owner says.
    public func labelled(_ labels: ModelLabels) -> ModelInfo {
        var model = self
        model.tags = labels.tags.filter { !ModelTag.needsVision($0) || capabilities.contains(.vision) }
        model.onlyWhenAsked = labels.onlyWhenAsked
        return model
    }
}

/// The work a model is trusted with, as its owner says: the documented
/// vocabulary, which means the same in every mesh, and tags of the owner's
/// own (docs/design.md, Capabilities and tags).
public enum ModelTag {
    public struct Documented: Sendable, Identifiable, Equatable {
        public let id: String
        /// What a client can rely on a model with the tag to do.
        public let promise: String
        /// Whether it applies only to a model that reads images.
        public let needsVision: Bool
    }

    /// In the order the app shows them.
    public static let vocabulary: [Documented] = [
        Documented(id: "image-description",
                   promise: "Say accurately what an image shows, in plain words: subjects, actions, arrangement, faces, text",
                   needsVision: true),
        Documented(id: "image-critique",
                   promise: "Judge how an image works, not only what's in it: composition, light, mood, and which of several is strongest",
                   needsVision: true),
        Documented(id: "editorial", promise: "Choose, order and cut among many items toward a goal, and say why",
                   needsVision: false),
        Documented(id: "writing", promise: "Write prose with a voice, for people to read", needsVision: false),
        Documented(id: "reasoning", promise: "Work through multi-step problems, plans and analysis",
                   needsVision: false),
        Documented(id: "code", promise: "Write and review code", needsVision: false),
        Documented(id: "tools", promise: "Choose and call tools reliably", needsVision: false),
    ]

    /// The terms that aren't tags: what conflux reads for itself.
    static let facts: Set<String> = ["any", "text", "vision", "unfiltered"]

    public static func isDocumented(_ tag: String) -> Bool { vocabulary.contains { $0.id == tag } }

    /// Whether the tag applies only to a model that reads images.
    public static func needsVision(_ tag: String) -> Bool {
        vocabulary.first { $0.id == tag }?.needsVision ?? false
    }

    /// Why a tag the owner typed can't be one of their own, or nil if it
    /// can: lowercase letters, digits and hyphens, starting with a letter,
    /// and not a fact's name or one of the vocabulary's.
    public static func problem(withCustom tag: String) -> String? {
        if tag.isEmpty { return "Type a tag first." }
        if tag.count > 32 { return "Use 32 characters at most." }
        guard let first = tag.unicodeScalars.first, ("a"..."z").contains(first),
              tag.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return "Use lowercase letters, digits and hyphens, starting with a letter." }
        if facts.contains(tag) || tag.hasPrefix("context-") { return "conflux uses that name itself." }
        if isDocumented(tag) { return "That's one of the tags above." }
        return nil
    }

    /// Whether a tag is well formed, documented or the owner's own.
    public static func isValid(_ tag: String) -> Bool {
        isDocumented(tag) || problem(withCustom: tag) == nil
    }
}

/// What the owner says about a model: the work it's trusted with, and
/// whether it answers only when asked for.
public struct ModelLabels: Sendable, Equatable, Codable {
    /// Lowercased, well formed, each once, sorted.
    public let tags: [String]
    public let onlyWhenAsked: Bool

    public init(tags: [String] = [], onlyWhenAsked: Bool = false) {
        self.tags = Set(tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            .filter(ModelTag.isValid).sorted()
        self.onlyWhenAsked = onlyWhenAsked
    }

    enum CodingKeys: String, CodingKey { case tags, onlyWhenAsked }

    /// Settings edited by hand are held to the same rules.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tags: try values.decodeIfPresent([String].self, forKey: .tags) ?? [],
                  onlyWhenAsked: try values.decodeIfPresent(Bool.self, forKey: .onlyWhenAsked) ?? false)
    }

    /// The same, with a tag added or taken away.
    public func with(_ tag: String, _ on: Bool) -> ModelLabels {
        ModelLabels(tags: on ? tags + [tag] : tags.filter { $0 != tag }, onlyWhenAsked: onlyWhenAsked)
    }

    /// The same, held back or not.
    public func held(_ onlyWhenAsked: Bool) -> ModelLabels {
        ModelLabels(tags: tags, onlyWhenAsked: onlyWhenAsked)
    }

    /// What a model is labelled before its owner says: Apple's model by
    /// conflux, any other with nothing.
    public static func defaults(for modelID: String) -> ModelLabels {
        modelID == AppleModelHost.modelID ? AppleModelHost.defaultLabels : ModelLabels()
    }
}

/// Which models a request accepts, from its `model` field and its
/// `Conflux-Models` header (docs/clients.md).
public struct ModelChoice: Sendable, Equatable {
    public enum Option: Sendable, Equatable {
        case exact(String)
        /// Any model with what the request needs.
        case needs(Needs)

        /// Any model that answers requests for any model.
        public static let any = Option.needs(Needs())
        public static func capability(_ capability: ModelInfo.Capability) -> Option {
            .needs(Needs(vision: capability == .vision))
        }
        /// A model with no content filter, and with the capability if one is
        /// given.
        public static func unfiltered(_ capability: ModelInfo.Capability?) -> Option {
            .needs(Needs(vision: capability == .vision, unfiltered: true))
        }

        public func accepts(_ model: ModelInfo) -> Bool {
            switch self {
            case .exact(let id): id == model.id
            case .needs(let needs): needs.accepts(model)
            }
        }

        /// As a client would write it.
        public var name: String {
            switch self {
            case .exact(let id): id
            case .needs(let needs): needs.name
            }
        }
    }

    /// What a request needs of a model, from `any` and the terms joined to
    /// it with `+`: facts conflux reads for itself, and tags.
    public struct Needs: Sendable, Equatable, Hashable {
        public var vision: Bool
        public var unfiltered: Bool
        /// The fewest tokens of context per slot.
        public var contextTokens: Int?
        public var tags: Set<String>

        public init(vision: Bool = false, unfiltered: Bool = false, contextTokens: Int? = nil,
                    tags: Set<String> = []) {
            self.vision = vision
            self.unfiltered = unfiltered
            self.contextTokens = contextTokens
            self.tags = tags
        }

        /// From `any`, an `any-` alias, or either with terms joined with
        /// `+`. Nil for anything else, which names a model.
        public init?(_ name: String) {
            let terms = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            switch terms[0] {
            case "any": self.init()
            case "any-vision": self.init(vision: true)
            case "any-unfiltered": self.init(unfiltered: true)
            case "any-vision-unfiltered": self.init(vision: true, unfiltered: true)
            default: return nil
            }
            for term in terms.dropFirst() {
                switch term {
                case "text": break
                case "vision": vision = true
                case "unfiltered": unfiltered = true
                case _ where term.hasPrefix("context-"):
                    guard term.hasSuffix("k"), let thousands = Int(term.dropFirst(8).dropLast()), thousands > 0
                    else { return nil }
                    contextTokens = max(contextTokens ?? 0, thousands * 1024)
                default:
                    guard ModelTag.isValid(term) else { return nil }
                    tags.insert(term)
                    if ModelTag.needsVision(term) { vision = true }
                }
            }
        }

        /// A model held back answers only a request naming one of its tags.
        public func accepts(_ model: ModelInfo) -> Bool {
            if model.onlyWhenAsked, tags.isDisjoint(with: model.tags) { return false }
            if vision, !model.capabilities.contains(.vision) { return false }
            if unfiltered, model.contentFilter { return false }
            if let contextTokens, (model.contextTokens ?? 0) < contextTokens { return false }
            return tags.isSubset(of: model.tags)
        }

        /// The shortest way to write it: an alias where there is one, then
        /// the rest, sorted.
        public var name: String {
            var rest: [String] = []
            if let contextTokens { rest.append("context-\((contextTokens + 1023) / 1024)k") }
            rest += tags.sorted()
            guard !rest.isEmpty else {
                return (["any"] + (vision ? ["vision"] : []) + (unfiltered ? ["unfiltered"] : []))
                    .joined(separator: "-")
            }
            var facts: [String] = []
            if vision, !tags.contains(where: ModelTag.needsVision) { facts.append("vision") }
            if unfiltered { facts.append("unfiltered") }
            return (["any"] + facts + rest).joined(separator: "+")
        }
    }

    /// In the client's order of preference.
    public var options: [Option]

    public init(options: [Option]) { self.options = options }

    /// `Conflux-Models` wins when present. Otherwise `model`, where an empty
    /// or missing value accepts any model.
    public init(model: String?, preference: String?) {
        let names: [String]
        if let preference, !preference.trimmingCharacters(in: .whitespaces).isEmpty {
            names = preference.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let model, !model.isEmpty {
            names = [model]
        } else {
            names = ["any"]
        }
        options = names.map { name in Needs(name).map(Option.needs) ?? .exact(name) }
    }

    /// The position of the first option this model satisfies, or nil if none
    /// does. Lower is more preferred.
    public func rank(_ model: ModelInfo) -> Int? {
        options.firstIndex { $0.accepts(model) }
    }
}
