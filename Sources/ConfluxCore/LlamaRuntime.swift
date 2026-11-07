import Darwin
import Foundation
import llama

/// The llama.cpp linked into conflux, from the binary target in
/// Package.swift.
public enum LlamaRuntime {
    /// The llama.cpp build number. Keep it in step with Package.swift.
    public static let build = 12110

    /// Starts llama.cpp's backends once, with its log sent to `LlamaLog`.
    static func initialize() { _ = initialized }

    private static let initialized: Void = {
        llama_log_set(llamaLogCallback, nil)
        mtmd_helper_log_set(llamaLogCallback, nil)
        llama_backend_init()
    }()

    /// Threads for the CPU's share of the work: the performance cores,
    /// as llama-server uses.
    static var threads: Int32 {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return cores }
        return Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}

/// Where llama.cpp's log goes: a file, plus the recent warnings, which the
/// self-check passes on as advice.
final class LlamaLog: @unchecked Sendable {
    static let shared = LlamaLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var warnings: [String] = []
    private var dropped = 0
    private var level = GGML_LOG_LEVEL_INFO

    /// Sends the log to `url`, appending. Until then it's dropped.
    func open(_ url: URL) {
        let handle: FileHandle? = {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            return handle
        }()
        lock.withLock {
            try? self.handle?.close()
            self.handle = handle
        }
    }

    func note(_ text: String) { write(GGML_LOG_LEVEL_INFO, text) }

    func write(_ level: ggml_log_level, _ text: String) {
        lock.withLock {
            // A continuation belongs to the line before it.
            if level != GGML_LOG_LEVEL_CONT { self.level = level }
            if self.level == GGML_LOG_LEVEL_WARN || self.level == GGML_LOG_LEVEL_ERROR {
                warnings.append(text)
                if warnings.count > 200 {
                    warnings.removeFirst(100)
                    dropped += 100
                }
            }
            if self.level != GGML_LOG_LEVEL_DEBUG { handle?.write(Data(text.utf8)) }
        }
    }

    /// A place in the warnings, to read what came after it.
    func mark() -> Int { lock.withLock { dropped + warnings.count } }

    func warnings(since mark: Int) -> String {
        lock.withLock { warnings.dropFirst(max(0, mark - dropped)).joined() }
    }
}

private let llamaLogCallback: ggml_log_callback = { level, text, _ in
    guard let text else { return }
    LlamaLog.shared.write(level, String(cString: text))
}
