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
/// Mode halve it.
public enum ResourcePolicy {
    public static func limit(slots: Int, reading: ResourceReading) -> (slots: Int, reason: String?) {
        if reading.thermal == .critical { return (0, "too hot: thermal state is critical") }
        if reading.memory == .critical { return (0, "memory pressure is critical") }
        var reasons: [String] = []
        if reading.thermal == .serious { reasons.append("thermal state is serious") }
        if reading.memory == .warning { reasons.append("memory pressure is elevated") }
        if reading.lowPowerMode { reasons.append("Low Power Mode is on") }
        guard !reasons.isEmpty else { return (slots, nil) }
        return (max(1, slots / 2), "halved: " + reasons.joined(separator: ", "))
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
