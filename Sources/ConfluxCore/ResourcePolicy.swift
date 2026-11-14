import Dispatch
import Foundation

/// What the device is going through right now.
public struct ResourceReading: Sendable, Equatable {
    public enum Memory: Sendable, Equatable { case normal, warning, critical }

    public var thermal: ProcessInfo.ThermalState
    public var memory: Memory
    public var lowPowerMode: Bool

    public init(thermal: ProcessInfo.ThermalState = .nominal, memory: Memory = .normal, lowPowerMode: Bool = false) {
        self.thermal = thermal
        self.memory = memory
        self.lowPowerMode = lowPowerMode
    }
}

/// How many slots a host may use under a reading (docs/design.md, *Resource
/// policy*). Pauses before it hurts the device: critical heat or memory
/// pressure stops new work, and serious heat, memory warnings or Low Power
/// Mode halve it, leaving at least one slot.
///
/// With `coolDown`, the owner's choice, serious heat stops new work too, so
/// the device rests until it's back to fair rather than staying hot. Heat
/// ages a battery, and a device that serves all day while charging stays
/// hot.
public enum ResourcePolicy {
    public static func limit(slots: Int, reading: ResourceReading,
                             coolDown: Bool = false) -> (slots: Int, reason: String?) {
        if reading.thermal == .critical { return (0, "too hot: thermal state is critical") }
        if reading.memory == .critical { return (0, "memory pressure is critical") }
        if coolDown && reading.thermal == .serious { return (0, "cooling down: thermal state is serious") }
        var reasons: [String] = []
        if reading.thermal == .serious { reasons.append("thermal state is serious") }
        if reading.memory == .warning { reasons.append("memory pressure is elevated") }
        if reading.lowPowerMode { reasons.append("Low Power Mode is on") }
        guard !reasons.isEmpty else { return (slots, nil) }
        return (max(1, slots / 2), "halved: " + reasons.joined(separator: ", "))
    }

    /// What the Heat tile shows for hosts with these slots: whether its Cool
    /// down box is checked, and by whom, and a word for what resource policy
    /// is doing about it.
    ///
    /// The box is checked and can't be changed while policy has paused the
    /// hosts by itself, since unchecking it couldn't resume them. Otherwise
    /// it shows the owner's choice, which may still take more slots away.
    public static func heat(slots: [Int], reading: ResourceReading, coolDown: Bool) -> HeatStatus {
        let total = slots.reduce(0, +)
        let choice: HeatStatus.Box = coolDown ? .on : .off
        guard total > 0 else { return HeatStatus(box: choice) }
        let automatic = slots.map { limit(slots: $0, reading: reading).slots }.reduce(0, +)
        let chosen = slots.map { limit(slots: $0, reading: reading, coolDown: coolDown).slots }.reduce(0, +)
        if automatic == 0 { return HeatStatus(box: .automatic, action: "paused") }
        if chosen < automatic { return HeatStatus(box: choice, action: "resting") }
        if automatic < total { return HeatStatus(box: choice, action: "halved") }
        return HeatStatus(box: choice)
    }
}

/// The Heat tile's Cool down box and what resource policy is doing
/// (`ResourcePolicy.heat`).
public struct HeatStatus: Sendable, Equatable {
    public enum Box: Sendable, Equatable {
        /// Unchecked: nothing rests the hosts at serious heat.
        case off
        /// Checked by the owner: the hosts rest at serious heat.
        case on
        /// Checked by resource policy, which has paused the hosts itself.
        case automatic
    }

    public var box: Box
    /// "resting", "halved" or "paused", or nil while nothing is held back.
    public var action: String?

    public init(box: Box, action: String? = nil) {
        self.box = box
        self.action = action
    }
}

/// Watches thermal state, memory pressure and Low Power Mode, and reports a
/// new reading whenever one changes.
public final class ResourceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: ResourceReading.Memory = .normal
    private var source: DispatchSourceMemoryPressure?
    private var polling: Task<Void, Never>?
    private var last: ResourceReading?

    public init() {}

    public var reading: ResourceReading {
        lock.withLock {
            ResourceReading(thermal: ProcessInfo.processInfo.thermalState, memory: memory,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    /// Calls `changed` with the first reading and then on every change.
    public func start(_ changed: @escaping @Sendable (ResourceReading) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            let level: ResourceReading.Memory = event.contains(.critical) ? .critical
                : event.contains(.warning) ? .warning : .normal
            self.lock.withLock { self.memory = level }
            self.report(changed)
        }
        source.resume()
        lock.withLock { self.source = source }

        // Thermal state and Low Power Mode change rarely; checking every two
        // seconds is cheaper than juggling their notifications.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.report(changed)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        polling?.cancel()
        lock.withLock {
            source?.cancel()
            source = nil
        }
    }

    private func report(_ changed: @Sendable (ResourceReading) -> Void) {
        let now = reading
        let isNew = lock.withLock { () -> Bool in
            defer { last = now }
            return last != now
        }
        if isNew { changed(now) }
    }
}
