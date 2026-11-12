import Foundation

/// How a host runs one model.
public struct ModelConfig: Sendable, Equatable, Codable {
    /// What runs the model.
    public enum Runtime: String, Sendable, Codable, CaseIterable {
        /// llama.cpp linked into conflux. Works in a sandboxed app, and the
        /// only choice on iPad.
        case inProcess = "in-process"
        /// A supervised `llama-server` process, on a Mac with llama.cpp
        /// installed. A crash in the model can't take the gateway down,
        /// but a sandboxed app can't run it.
        case llamaServer = "llama-server"
    }

    public var runtime: Runtime
    /// The GGUF model file.
    public var model: String
    /// The multimodal projector, for vision models.
    public var projector: String?
    /// Requests run at once.
    public var slots: Int
    /// Context, in tokens, for each slot.
    public var contextPerSlot: Int
    /// Clients are told to send images no larger than this on their longer
    /// side.
    public var maxImageDimension: Int
    /// The fewest tokens an image is given. Some models read small images
    /// badly with fewer: Qwen-VL models want 1,024. Nil uses the model's own
    /// setting.
    public var imageMinTokens: Int?
    public var selfCheck: Bool
    /// Path to `llama-server`, for that runtime. Nil looks in the usual
    /// Homebrew locations and on `PATH`.
    public var executable: String?
    /// More arguments for `llama-server`, added last.
    public var extraArguments: [String]

    public init(runtime: Runtime = .inProcess, model: String, projector: String? = nil, slots: Int = 1,
                contextPerSlot: Int = 4096, maxImageDimension: Int = 1024, imageMinTokens: Int? = nil,
                selfCheck: Bool = true, executable: String? = nil, extraArguments: [String] = []) {
        self.runtime = runtime
        self.model = model
        self.projector = projector
        self.slots = slots
        self.contextPerSlot = contextPerSlot
        self.maxImageDimension = maxImageDimension
        self.imageMinTokens = imageMinTokens
        self.selfCheck = selfCheck
        self.executable = executable
        self.extraArguments = extraArguments
    }

    /// Settings saved by earlier versions lack the newer fields, and still
    /// load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ModelConfig(model: "")
        runtime = try c.decodeIfPresent(Runtime.self, forKey: .runtime) ?? defaults.runtime
        model = try c.decode(String.self, forKey: .model)
        projector = try c.decodeIfPresent(String.self, forKey: .projector)
        slots = try c.decodeIfPresent(Int.self, forKey: .slots) ?? defaults.slots
        contextPerSlot = try c.decodeIfPresent(Int.self, forKey: .contextPerSlot) ?? defaults.contextPerSlot
        maxImageDimension = try c.decodeIfPresent(Int.self, forKey: .maxImageDimension) ?? defaults.maxImageDimension
        imageMinTokens = try c.decodeIfPresent(Int.self, forKey: .imageMinTokens)
        selfCheck = try c.decodeIfPresent(Bool.self, forKey: .selfCheck) ?? defaults.selfCheck
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
    }

    /// The artifact ID: the model file's name without `.gguf`.
    public var modelID: String {
        let name = URL(fileURLWithPath: model).lastPathComponent
        return name.lowercased().hasSuffix(".gguf") ? String(name.dropLast(5)) : name
    }

    var files: [String] { [model] + (projector.map { [$0] } ?? []) }

    var capabilities: Set<ModelInfo.Capability> { projector == nil ? [.text] : [.text, .vision] }
}

extension ModelConfig {
    /// Context sizes, in tokens, the app offers for each slot.
    public static let contextSizes = [1024, 2048, 4096, 8192, 16384, 32768, 65536]
    /// Longest image sides, in pixels, the app offers.
    public static let imageSides = [256, 512, 768, 1024, 1536, 2048, 3072, 4096]

    /// The sizes to offer, in order, with `current` among them when it isn't
    /// one already, so a value saved some other way still shows and stays
    /// chosen.
    public static func choices(_ sizes: [Int], including current: Int) -> [Int] {
        sizes.contains(current) ? sizes : (sizes + [current]).sorted()
    }
}
