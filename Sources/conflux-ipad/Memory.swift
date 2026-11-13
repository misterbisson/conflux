import ConfluxUI
import Darwin
import Foundation
import os

/// What iPadOS lets this process use, and what it uses.
///
/// iPadOS ends an app that goes past its per-app memory limit, with no
/// chance to report it. So the probe reads what's left before and after
/// loading a model, and a run that never finishes is the sign a model was
/// too big.
enum Memory {
    /// What this process can still allocate before iPadOS ends it.
    static var available: UInt64 { UInt64(os_proc_available_memory()) }

    /// The process's memory footprint now, and the highest it has been since
    /// launch. The footprint is what iPadOS counts against the limit.
    static var footprint: (now: UInt64, peak: UInt64) { ProcessMemory.footprint }

    /// The model of device, such as `iPad13,4`: which kind of iPad, not which
    /// one.
    static var machine: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func gigabytes(_ bytes: UInt64) -> String { ProcessMemory.gigabytes(bytes) }

    /// To a tenth of a gigabyte, for an estimate or a limit in words.
    static func roughly(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
