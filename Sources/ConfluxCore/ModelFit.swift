import Foundation

/// How much memory a model is likely to take, worked out from its files and
/// its header before it's loaded, and whether that's likely to fit in what a
/// device allows.
///
/// On an iPad, iPadOS ends an app that goes past its memory limit, with no
/// warning, so otherwise the only way to learn whether a model fits is to
/// load it. This is a hint, never a block, and it errs towards saying a model
/// may not fit: the memory it counts, and the room it keeps, are each on the
/// large side.
public struct ModelFit: Sendable, Equatable {
    /// The model's and projector's files, whole. llama.cpp reads the
    /// projector into memory, and the model's weights stay in memory for the
    /// GPU. Counting all of both errs large.
    public var weights: UInt64
    /// What every slot's context takes, or nil when the model's header
    /// doesn't say enough to work it out.
    public var context: UInt64?
    /// Room for what neither counts: `base`, and `perSlot` for each slot.
    public var working: UInt64
    /// The most tokens the model was trained to read, when each slot's
    /// context is larger. llama.cpp makes the context as large as asked
    /// anyway, so the memory is still taken.
    public var trainedContext: Int?

    /// The estimate: the files, the context and the working room.
    public var total: UInt64 { Self.plus(Self.plus(weights, context ?? 0), working) }

    public init(model: GGUFMetadata?, modelBytes: UInt64, projectorBytes: UInt64?, slots: Int,
                contextPerSlot: Int) {
        let slots = UInt64(max(1, slots))
        weights = Self.plus(modelBytes, projectorBytes ?? 0)
        context = model.flatMap { Self.contextBytes($0, tokens: contextPerSlot) }.map { Self.times($0, slots) }
        working = Self.plus(Self.base, Self.times(Self.perSlot, slots))
        trainedContext = model?.contextLength.flatMap { contextPerSlot > $0 ? $0 : nil }
    }

    /// Whether the estimate is within what's usable of what's allowed.
    public func likelyFits(allowed: UInt64, physicalMemory: UInt64) -> Bool {
        total <= Self.usable(allowed: allowed, physicalMemory: physicalMemory)
    }

    // MARK: The margin

    /// The share of what's allowed that the estimate keeps back.
    ///
    /// iPadOS can report a limit as large as all of the iPad's memory: 8 GB
    /// at launch on an 8 GB iPad Pro, with the increased-memory-limit
    /// entitlement. iPadOS itself, and the apps it keeps, need some of that,
    /// and when memory runs short it ends the largest app first. The quarter
    /// kept back is for them, and for what the estimate can't see: llama.cpp
    /// and Metal rounding buffers up, and memory freed but not returned.
    public static let reserve = 0.25

    /// The device memory kept for iPadOS and the apps it keeps, whatever it
    /// allows conflux.
    ///
    /// The increased-memory-limit entitlement can let conflux use more than
    /// the device can spare once a model is loaded: its weights and context
    /// are wired for the GPU, and iPadOS can neither compress nor page them
    /// out. An 8 GB iPad Pro serving a 4B vision model, well inside the
    /// 6 GB a quarter's reserve left it, ran the whole device short: iPadOS
    /// ended hundreds of other processes, and then conflux. So on an 8 GB
    /// iPad a model and its context can likely use 4.5 GB, and a larger
    /// iPad keeps the same room.
    public static let systemReserve: UInt64 = 3584 << 20

    /// The room any loaded model takes beyond its files and context: the app
    /// itself, llama.cpp and Metal, and the projector's work on an image.
    public static let base: UInt64 = 512 << 20

    /// The room each slot takes beyond its context: each is a llama.cpp
    /// context of its own, with buffers for working through 512 tokens at a
    /// time and for the scores of every token the model knows.
    public static let perSlot: UInt64 = 256 << 20

    /// The context of a typical model, for saying how large a model fits
    /// before one is chosen: 4,096 tokens of an 8B model with grouped-query
    /// attention, 32 layers of 8 key/value heads 128 wide, at f16.
    public static let typicalContext: UInt64 = 512 << 20

    /// How much of `allowed` a model can likely use: the smaller of it and
    /// the device's memory, less `reserve`, and no more than the device's
    /// memory less `systemReserve`.
    public static func usable(allowed: UInt64, physicalMemory: UInt64) -> UInt64 {
        guard physicalMemory > 0 else { return UInt64(Double(allowed) * (1 - reserve)) }
        let share = UInt64(Double(min(allowed, physicalMemory)) * (1 - reserve))
        let spare = physicalMemory > systemReserve ? physicalMemory - systemReserve : 0
        return min(share, spare)
    }

    /// The largest model, with its projector, that likely loads with one
    /// slot and a typical context, rounded down to half a gigabyte.
    public static func largestModel(allowed: UInt64, physicalMemory: UInt64) -> UInt64 {
        let room = base + perSlot + typicalContext
        let usable = usable(allowed: allowed, physicalMemory: physicalMemory)
        guard usable > room else { return 0 }
        let half: UInt64 = 512 << 20
        return (usable - room) / half * half
    }

    // MARK: The context

    /// What one slot's context of `tokens` takes for `model`, or nil when
    /// its header doesn't say enough.
    ///
    /// llama.cpp keeps a key and a value for each token, in each layer, for
    /// each of the layer's key/value heads, as wide as the heads are. conflux
    /// leaves the cache at llama.cpp's default, f16, two bytes a number
    /// (LlamaHost sets no cache type). Some models keep less, such as those
    /// with sliding-window layers, which keep only their window: counting
    /// all of it errs large.
    public static func contextBytes(_ model: GGUFMetadata, tokens: Int) -> UInt64? {
        guard !model.isProjector, let layers = model.blockCount, layers > 0, tokens > 0 else { return nil }
        let headWidth = model.embeddingLength.flatMap { embedding in model.headCount.map { embedding / $0 } }
        guard let keyWidth = model.keyLength ?? headWidth, let valueWidth = model.valueLength ?? headWidth else {
            return nil
        }
        // One count for every layer, one for each, or, as llama.cpp reads a
        // header without it, as many as the attention heads.
        let heads: [Int]
        switch model.headCountKV ?? model.headCount.map({ [$0] }) {
        case let counts? where counts.count == 1: heads = Array(repeating: counts[0], count: layers)
        case let counts? where counts.count == layers: heads = counts
        // A list that doesn't match the layers: the most in each, to err large.
        case let counts?: heads = Array(repeating: counts.max() ?? 0, count: layers)
        case nil: return nil
        }
        // llama.cpp rounds the context up to a multiple of 256 tokens.
        let padded = (Double(tokens) / 256).rounded(.up) * 256
        let bytesPerToken = Double(heads.reduce(0, +)) * Double(keyWidth + valueWidth) * 2
        return saturating(bytesPerToken * padded)
    }

    private static func plus(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    private static func times(_ bytes: UInt64, _ count: UInt64) -> UInt64 {
        let (product, overflow) = bytes.multipliedReportingOverflow(by: count)
        return overflow ? .max : product
    }

    private static func saturating(_ bytes: Double) -> UInt64 {
        bytes >= Double(UInt64.max) ? .max : UInt64(bytes)
    }
}
