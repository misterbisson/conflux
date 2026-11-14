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

    public enum Capability: String, Sendable, Codable, CaseIterable {
        case text, vision
    }

    public init(id: String, capabilities: Set<Capability>, fingerprint: String, maxImageDimension: Int? = nil,
                contentFilter: Bool = false) {
        self.id = id
        self.capabilities = capabilities
        self.fingerprint = fingerprint
        self.maxImageDimension = maxImageDimension
        self.contentFilter = contentFilter
    }

    enum CodingKeys: String, CodingKey {
        case id, capabilities, fingerprint, maxImageDimension, contentFilter
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
    }
}

/// Which models a request accepts, from its `model` field and its
/// `Conflux-Models` header (docs/clients.md).
public struct ModelChoice: Sendable, Equatable {
    public enum Option: Sendable, Equatable {
        case exact(String)
        case any
        case capability(ModelInfo.Capability)
        /// A model with the capability and no content filter.
        case unfiltered(ModelInfo.Capability)

        public func accepts(_ model: ModelInfo) -> Bool {
            switch self {
            case .exact(let id): id == model.id
            case .any: true
            case .capability(let capability): model.capabilities.contains(capability)
            case .unfiltered(let capability): model.capabilities.contains(capability) && !model.contentFilter
            }
        }
    }

    /// In the client's order of preference.
    public var options: [Option]

    public static let aliases: [String: Option] = [
        "any": .any, "any-vision": .capability(.vision), "any-vision-unfiltered": .unfiltered(.vision),
    ]

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
        options = names.map { ModelChoice.aliases[$0] ?? .exact($0) }
    }

    /// The position of the first option this model satisfies, or nil if none
    /// does. Lower is more preferred.
    public func rank(_ model: ModelInfo) -> Int? {
        options.firstIndex { $0.accepts(model) }
    }
}
