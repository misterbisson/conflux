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

    public enum Capability: String, Sendable, Codable, CaseIterable {
        case text, vision
    }

    public init(id: String, capabilities: Set<Capability>, fingerprint: String, maxImageDimension: Int? = nil) {
        self.id = id
        self.capabilities = capabilities
        self.fingerprint = fingerprint
        self.maxImageDimension = maxImageDimension
    }
}

/// Which models a request accepts, from its `model` field and its
/// `Conflux-Models` header (docs/clients.md).
public struct ModelChoice: Sendable, Equatable {
    public enum Option: Sendable, Equatable {
        case exact(String)
        case any
        case capability(ModelInfo.Capability)
    }

    /// In the client's order of preference.
    public var options: [Option]

    public static let aliases: [String: Option] = ["any": .any, "any-vision": .capability(.vision)]

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
        options.firstIndex { option in
            switch option {
            case .exact(let id): id == model.id
            case .any: true
            case .capability(let capability): model.capabilities.contains(capability)
            }
        }
    }
}
