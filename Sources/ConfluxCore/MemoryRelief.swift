import Foundation

/// Frees a host's model when memory pressure stays critical, and loads it
/// again once pressure has been normal for a while (docs/design.md,
/// *Resource policy*).
///
/// Pausing at critical pressure takes no new work, but frees nothing: the
/// model's weights and each slot's context stay in memory. On an iPad most
/// of that is wired for the GPU, which iPadOS can neither compress nor page
/// out, so when the whole device runs short it ends processes, and conflux,
/// the largest, among them. Unloading the model gives that memory back.
///
/// Pure, so tests drive it with their own clock. `ConfluxNode` feeds it
/// each memory reading and asks again at `nextCheck`.
public struct MemoryRelief: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        /// Unload the model: no slots, stopping requests running.
        case release
        /// Load it again, with the slots its owner asked for.
        case restore
    }

    /// How long pressure stays critical before the model goes. Long enough
    /// to ride out a spike, short enough to act before iPadOS does.
    public static let grace: Duration = .seconds(5)
    /// How long pressure is normal before the model comes back, the first
    /// time.
    public static let recovery: Duration = .seconds(60)
    /// The longest it waits to come back. A model that pushes pressure
    /// back to critical soon after loading waits twice as long each time,
    /// up to this.
    public static let longestRecovery: Duration = .seconds(30 * 60)
    /// Released again within this long of coming back counts as soon.
    public static let soon: Duration = .seconds(10 * 60)

    /// What a host whose model was unloaded says it's doing.
    public static let reason = "memory ran short, so its model is unloaded until memory pressure is back to normal"

    /// Whether the model is unloaded.
    public private(set) var released = false
    /// How long pressure must be normal before it comes back.
    public private(set) var wait: Duration = Self.recovery
    private var criticalSince: ContinuousClock.Instant?
    private var normalSince: ContinuousClock.Instant?
    private var restoredAt: ContinuousClock.Instant?

    public init() {}

    /// Takes the memory pressure now, and says what to do about it.
    public mutating func observe(_ memory: ResourceReading.Memory, at now: ContinuousClock.Instant) -> Action {
        criticalSince = memory == .critical ? criticalSince ?? now : nil
        normalSince = memory == .normal ? normalSince ?? now : nil
        if !released, let since = criticalSince, now - since >= Self.grace {
            released = true
            criticalSince = nil
            let again = restoredAt.map { now - $0 < Self.soon } ?? false
            wait = again ? min(wait * 2, Self.longestRecovery) : Self.recovery
            return .release
        }
        if released, let since = normalSince, now - since >= wait {
            released = false
            restoredAt = now
            return .restore
        }
        return .none
    }

    /// When to observe again if nothing changes before then: when critical
    /// pressure will have lasted `grace`, or normal pressure `wait`.
    public var nextCheck: ContinuousClock.Instant? {
        if released { return normalSince.map { $0 + wait } }
        return criticalSince.map { $0 + Self.grace }
    }

    /// The Memory pressure tile's word for what resource policy is doing
    /// about memory to hosts with these slots: "unloaded", "paused" or
    /// "halved", or nil while memory holds nothing back.
    public func action(slots: [Int], memory: ResourceReading.Memory) -> String? {
        if released { return "unloaded" }
        guard slots.reduce(0, +) > 0 else { return nil }
        switch memory {
        case .critical: return "paused"
        case .warning:
            let limited = slots.map { ResourcePolicy.limit(slots: $0, reading: ResourceReading(memory: .warning)).slots }
            return limited.reduce(0, +) < slots.reduce(0, +) ? "halved" : nil
        case .normal: return nil
        }
    }
}

/// The device's memory pressure, and what resource policy is doing about
/// it, for the Memory pressure tile.
public struct MemoryStatus: Sendable, Equatable {
    public var pressure: ResourceReading.Memory
    /// "unloaded", "paused" or "halved", or nil (`MemoryRelief.action`).
    public var action: String?

    public init(pressure: ResourceReading.Memory = .normal, action: String? = nil) {
        self.pressure = pressure
        self.action = action
    }

    /// Normal, Warning or Critical, the system's own names for the levels.
    public var label: String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// The pressure as a level, 0 for normal to 2 for critical.
    public var level: Int {
        switch pressure {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
