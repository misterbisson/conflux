import CryptoKit
import Darwin
import Foundation

/// How to run one model with `llama-server`.
public struct LlamaServerConfig: Sendable, Equatable, Codable {
    /// Path to `llama-server`. Nil looks in the usual Homebrew locations and
    /// on `PATH`.
    public var executable: String?
    /// The GGUF model file.
    public var model: String
    /// The multimodal projector, for vision models.
    public var projector: String?
    /// Requests run at once. `llama-server --parallel`.
    public var slots: Int
    /// Context per slot. `llama-server` splits `-c` across slots, so it gets
    /// `slots × contextPerSlot`.
    public var contextPerSlot: Int
    public var maxImageDimension: Int
    public var selfCheck: Bool
    /// More arguments for `llama-server`, added last.
    public var extraArguments: [String]

    public init(executable: String? = nil, model: String, projector: String? = nil, slots: Int = 1,
                contextPerSlot: Int = 4096, maxImageDimension: Int = 1024, selfCheck: Bool = true,
                extraArguments: [String] = []) {
        self.executable = executable
        self.model = model
        self.projector = projector
        self.slots = slots
        self.contextPerSlot = contextPerSlot
        self.maxImageDimension = maxImageDimension
        self.selfCheck = selfCheck
        self.extraArguments = extraArguments
    }

    /// The artifact ID: the model file's name without `.gguf`.
    public var modelID: String {
        let name = URL(fileURLWithPath: model).lastPathComponent
        return name.lowercased().hasSuffix(".gguf") ? String(name.dropLast(5)) : name
    }

    public func arguments(port: Int) -> [String] {
        var arguments = ["--host", "127.0.0.1", "--port", String(port), "-m", model]
        if let projector { arguments += ["--mmproj", projector] }
        arguments += ["--parallel", String(slots), "-c", String(slots * contextPerSlot)]
        return arguments + extraArguments
    }
}

/// A model served by a `llama-server` process this host starts and watches
/// (docs/design.md, *Runtimes*).
///
/// Supervising a separate process keeps a runtime crash from taking the
/// gateway down. It also uses exactly what Phase 0 measured. The iPad host
/// will have to link llama.cpp in-process instead (Phase 3).
public final class LlamaServerHost: InferenceHost, @unchecked Sendable {
    public let id: String
    public let config: LlamaServerConfig
    public let logURL: URL
    public var slots: Int { config.slots }

    private let lock = NSLock()
    private var process: Process?
    private var port: Int?
    private var identity: ModelInfo?
    private var state: HostAvailability = .starting("not started")
    private var exits: [Date] = []
    private var stopping = false
    /// Where this launch's output starts in the log.
    private var logStart: UInt64 = 0
    private let session: URLSession

    public init(id: String = "local", config: LlamaServerConfig, logURL: URL = LlamaServerHost.defaultLogURL) {
        self.id = id
        self.config = config
        self.logURL = logURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = config.slots + 4
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
        // Provisional until the files are hashed, so requests arriving that
        // early hear "starting" rather than "no such model".
        identity = ModelInfo(id: config.modelID, capabilities: config.projector == nil ? [.text] : [.text, .vision],
                             fingerprint: "identifying",
                             maxImageDimension: config.projector == nil ? nil : config.maxImageDimension)
    }

    public static var defaultLogURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/conflux/llama-server.log")
    }

    /// Known once the files are identified, before the model has loaded, so
    /// requests arriving during startup hear "starting" and not "no such model".
    public var model: ModelInfo? {
        get async { lock.withLock { identity } }
    }

    public var availability: HostAvailability {
        get async { lock.withLock { state } }
    }

    private func set(_ new: HostAvailability) {
        lock.withLock { state = new }
    }

    // MARK: Lifecycle

    /// Identifies the model, starts `llama-server`, waits for it to load, and
    /// runs the self-check. Returns once the host is available or has failed.
    public func start() async {
        lock.withLock { stopping = false; exits = [] }
        guard let executable = LlamaServerHost.locate(config.executable) else {
            return set(.failed("llama-server not found; install llama.cpp (brew install llama.cpp) or set its path"))
        }
        for path in [config.model] + (config.projector.map { [$0] } ?? []) where !FileManager.default.fileExists(atPath: path) {
            return set(.failed("no file at \(path)"))
        }
        set(.starting("identifying the model"))
        let build = LlamaServerHost.build(of: executable)
        let digest: String
        do {
            digest = try await Task.detached(priority: .utility) { [config] in
                try FileHash.combined([config.model] + (config.projector.map { [$0] } ?? []))
            }.value
        } catch {
            return set(.failed("can't read the model file: \(error.localizedDescription)"))
        }
        let identity = ModelInfo(
            id: config.modelID,
            capabilities: config.projector == nil ? [.text] : [.text, .vision],
            fingerprint: "llama.cpp-\(build ?? "unknown")-sha256:\(digest.prefix(12))",
            maxImageDimension: config.projector == nil ? nil : config.maxImageDimension)
        lock.withLock { self.identity = identity }
        await launch(executable)
    }

    public func stop() {
        let process = lock.withLock { () -> Process? in
            stopping = true
            state = .offline
            return self.process
        }
        process?.terminate()
    }

    private func launch(_ executable: String) async {
        let port: Int
        do {
            port = try LlamaServerHost.freePort()
        } catch {
            return set(.failed("no free port for llama-server"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = config.arguments(port: port)
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            let offset = log.seekToEndOfFile()
            lock.withLock { logStart = offset }
            log.write(Data("\n--- \(Date()) \(executable) \(process.arguments?.joined(separator: " ") ?? "")\n".utf8))
            process.standardOutput = log
            process.standardError = log
        } catch {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] finished in
            self?.exited(finished, executable: executable)
        }
        // Registered before it runs: a process that exits at once must
        // still be recognized by `exited`, or nothing restarts it and the
        // host waits on it forever.
        let registered = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            self.process = process
            self.port = port
            state = .starting("loading the model")
            return true
        }
        guard registered else { return }
        do {
            try process.run()
        } catch {
            lock.withLock {
                if self.process === process { self.process = nil; self.port = nil }
            }
            return set(.failed("can't start llama-server: \(error.localizedDescription)"))
        }

        guard await waitUntilHealthy(port: port, process: process) else { return }

        if config.selfCheck {
            set(.starting("checking that the model reads its input"))
            if let problem = await selfCheck(port: port) {
                let advice = LlamaServerHost.advice(in: logSinceLaunch()).map { "; llama-server suggests: \($0)" } ?? ""
                set(.failed("self-check failed: \(problem)\(advice)"))
                process.terminate()
                return
            }
        }
        lock.withLock {
            if self.process === process && !stopping { state = .available }
        }
    }

    /// What llama-server has logged since this launch.
    private func logSinceLaunch() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: lock.withLock { logStart })
        let data = (try? handle.read(upToCount: 4 << 20)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// llama.cpp's own suggestions for a model that may read its input
    /// badly, from its warnings: "if you encounter problems with accuracy,
    /// try adding --image-min-tokens 1024". Passed on to the person, who
    /// can add the option, since it depends on the model.
    static func advice(in log: String) -> String? {
        let suggestions = log.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let range = line.range(of: "try adding ", options: .caseInsensitive) else { return nil }
            let suggestion = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return suggestion.hasPrefix("-") ? "add \(suggestion)" : nil
        }
        var seen: Set<String> = []
        let unique = suggestions.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "; ")
    }

    private func waitUntilHealthy(port: Int, process: Process) async -> Bool {
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        // Loading a large model from a cold disk can take minutes.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard process.isRunning, lock.withLock({ !stopping }) else { return false }
            var request = URLRequest(url: health, timeoutInterval: 2)
            request.httpMethod = "GET"
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        set(.failed("llama-server didn't finish loading in 10 minutes; see \(logURL.path)"))
        process.terminate()
        return false
    }

    /// Nil when the check passes, otherwise what went wrong. Three probes,
    /// each with fresh text, and all must pass: a working model reads them
    /// every time, while one that reads its input badly gets some right by
    /// luck, and a single probe wouldn't tell the two apart.
    func selfCheck(port: Int, probes: Int = 3) async -> String? {
        var misses: [String] = []
        for _ in 0..<probes {
            do {
                let probe = try SelfCheck.probe(vision: config.projector != nil)
                let reply = try await post(probe.body, port: port, timeout: 120)
                guard (200..<300).contains(reply.status) else { return "llama-server answered \(reply.status)" }
                let answer = SelfCheck.answer(in: reply.body) ?? ""
                if !SelfCheck.passes(answer: answer, expected: probe.expected) {
                    misses.append("asked to read \(probe.expected), it answered \(answer.prefix(60).debugDescription)")
                }
            } catch {
                return "\(error)"
            }
        }
        guard let first = misses.first else { return nil }
        return "\(misses.count) of \(probes) misread; \(first)"
    }

    private func exited(_ process: Process, executable: String) {
        let restart = lock.withLock { () -> Bool in
            guard self.process === process, !stopping else { return false }
            self.process = nil
            port = nil
            let now = Date()
            exits = exits.filter { now.timeIntervalSince($0) < 300 } + [now]
            let status = "llama-server exited with status \(process.terminationStatus)"
            if case .failed = state { return false }
            if exits.count > 3 {
                state = .failed("\(status), four times in five minutes; see \(logURL.path)")
                return false
            }
            state = .starting("restarting: \(status)")
            return true
        }
        guard restart else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await launch(executable)
        }
    }

    // MARK: Requests

    public func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
        guard let port = lock.withLock({ state == .available ? self.port : nil }) else {
            throw HostError.unavailable("llama-server isn't ready")
        }
        let reply = try await post(body, port: port, timeout: timeout)
        switch reply.status {
        case 200..<500 where reply.status != 408:
            return reply
        case 503:
            throw HostError.unavailable("llama-server is loading")
        default:
            throw HostError.failed(status: reply.status,
                                   message: String(decoding: reply.body.prefix(200), as: UTF8.self))
        }
    }

    private func post(_ body: Data, port: Int, timeout: TimeInterval) async throws -> HostReply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            return HostReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            throw HostError.unavailable(error.localizedDescription)
        }
    }

    // MARK: Helpers

    static func locate(_ configured: String?) -> String? {
        let manager = FileManager.default
        if let configured { return manager.isExecutableFile(atPath: configured) ? configured : nil }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] + path {
            let candidate = directory + "/llama-server"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The build number from `llama-server --version`, as `b12345`.
    static func build(of executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBuild(String(decoding: output, as: UTF8.self))
    }

    static func parseBuild(_ text: String) -> String? {
        guard let range = text.range(of: #"build (\d+)"#, options: .regularExpression) else { return nil }
        return "b" + text[range].dropFirst("build ".count)
    }

    /// A port nothing is listening on, found by binding port 0 and closing it.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// SHA-256 of model files, remembered by path, size and modification date,
/// because hashing gigabytes on every launch is slow.
enum FileHash {
    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "conflux/hashes.json")
    }

    /// One digest for several files, in order.
    static func combined(_ paths: [String]) throws -> String {
        let parts = try paths.map(sha256)
        if parts.count == 1 { return parts[0] }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(modified)"
        var cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))) ?? [:]
        if let known = cache[key] { return known }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        cache[key] = digest
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheURL)
        return digest
    }
}
