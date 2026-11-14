import Foundation
#if canImport(IOKit)
import IOKit
#endif
#if canImport(Metal)
import Metal
#endif

/// What kind of device a host runs on: its chip, cores and memory, as the
/// operating system reports them, so measurements can name each device's
/// hardware without anyone looking it up.
///
/// Only the class of hardware: never a serial number, hostname, hardware
/// UUID or anything else that tells one device, or its owner, from another
/// of the same kind. Each field is nil where the system doesn't say, rather
/// than guessed from a table of models.
public struct HardwareInfo: Sendable, Codable, Equatable {
    /// The chip, such as `Apple M4 Pro`.
    public var chip: String?
    /// CPU cores, by kind. Nil on a chip with one kind of core, or where the
    /// system doesn't say.
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    /// GPU cores. iPadOS doesn't say, so an iPad leaves it nil.
    public var gpuCores: Int?
    /// Memory, in bytes.
    public var memoryBytes: UInt64?
    /// The model of device, such as `Mac16,8` or `iPad13,4`: which kind, not
    /// which one.
    public var modelIdentifier: String?

    public init(chip: String? = nil, performanceCores: Int? = nil, efficiencyCores: Int? = nil,
                gpuCores: Int? = nil, memoryBytes: UInt64? = nil, modelIdentifier: String? = nil) {
        self.chip = chip
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.memoryBytes = memoryBytes
        self.modelIdentifier = modelIdentifier
    }

    /// This device's, read once.
    public static let current = HardwareInfo.read()

    /// Short, for a row: `M4 Pro, 16-core GPU, 48 GB`. Nil when there's
    /// nothing to say.
    public var summary: String? {
        let chip = chip.map { $0.hasPrefix("Apple ") ? String($0.dropFirst("Apple ".count)) : $0 }
        let parts = [chip ?? modelIdentifier,
                     gpuCores.map { "\($0)-core GPU" },
                     memoryBytes.map(Self.gigabytes)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `12-core CPU (8 performance, 4 efficiency)`, or nil when the system
    /// doesn't say.
    public var cpuCores: String? {
        guard let performance = performanceCores, let efficiency = efficiencyCores else { return nil }
        return "\(performance + efficiency)-core CPU (\(performance) performance, \(efficiency) efficiency)"
    }

    /// Whole gigabytes, as Apple counts a device's memory.
    static func gigabytes(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB"
    }

    static func read() -> HardwareInfo {
        let levels = sysctlInt("hw.nperflevels") ?? 0
        return HardwareInfo(
            chip: chipName(),
            performanceCores: levels > 1 ? sysctlInt("hw.perflevel0.physicalcpu") : nil,
            efficiencyCores: levels > 1 ? sysctlInt("hw.perflevel1.physicalcpu") : nil,
            gpuCores: gpuCoreCount(),
            memoryBytes: sysctlUInt64("hw.memsize"),
            // On a Mac `hw.model` names the model, and `hw.machine` the
            // architecture; on an iPad it's the other way round.
            modelIdentifier: sysctlString(isMac ? "hw.model" : "hw.machine"))
    }

    private static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The CPU's brand string where it names the chip, as it does on a Mac.
    /// Otherwise Metal's name for the GPU, which names the chip it's part
    /// of: `Apple M1 GPU` is the M1's.
    static func chipName() -> String? {
        if let brand = sysctlString("machdep.cpu.brand_string"), let chip = Self.chip(fromBrand: brand) {
            return chip
        }
        #if canImport(Metal)
        if let name = MTLCreateSystemDefaultDevice()?.name { return chip(fromGPU: name) }
        #endif
        return nil
    }

    /// A brand string that names an Apple chip, not a generic one such as
    /// `Apple processor`.
    static func chip(fromBrand brand: String) -> String? {
        let brand = brand.trimmingCharacters(in: .whitespaces)
        guard brand.hasPrefix("Apple "), !brand.lowercased().hasSuffix(" processor") else { return nil }
        return brand
    }

    /// `Apple M1 GPU` → `Apple M1`. Nil for a name that isn't an Apple chip's.
    static func chip(fromGPU name: String) -> String? {
        var name = name.trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("Apple ") else { return nil }
        if name.hasSuffix(" GPU") { name = String(name.dropLast(" GPU".count)) }
        return name == "Apple" ? nil : name
    }

    /// The GPU's `gpu-core-count`, from IOKit's accelerator. A Mac only:
    /// iPadOS has no IOKit for apps.
    static func gpuCoreCount() -> Int? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
        #else
        return nil
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : nil
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value > 0 ? value : nil
    }
}
