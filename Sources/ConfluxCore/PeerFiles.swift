import CryptoKit
import Darwin
import Foundation

/// A file a host serves, as it lists it to its peers.
public struct PeerFile: Sendable, Equatable, Codable, Identifiable {
    /// Which of the host's files: the only names a host serves a file by.
    public enum Role: String, Sendable, Codable, CaseIterable {
        case model
        case projector
    }

    public var role: Role
    /// The file's name on the host, which names the model: keep it, and a
    /// copy serves under the same model ID.
    public var name: String
    public var size: Int64
    /// Lowercase hex.
    public var sha256: String
    public var id: Role { role }

    public init(role: Role, name: String, size: Int64, sha256: String) {
        self.role = role
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// What a host offers its peers: the files of the model it serves, and what
/// it serves them as.
public struct PeerFileList: Sendable, Equatable, Codable {
    /// The model's ID, from its file's name. Nil when it serves no model file.
    public var modelID: String?
    /// The fingerprint it serves the model under, once it has identified it.
    public var fingerprint: String?
    /// The model, then its projector if it has one. Empty when the host
    /// serves no model file, or only Apple's model.
    public var files: [PeerFile]

    public init(modelID: String? = nil, fingerprint: String? = nil, files: [PeerFile] = []) {
        self.modelID = modelID
        self.fingerprint = fingerprint
        self.files = files
    }

    public var model: PeerFile? { files.first { $0.role == .model } }
    public var projector: PeerFile? { files.first { $0.role == .projector } }
    /// Both files together, in bytes.
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case fingerprint
        case files
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}

public enum PeerFilesError: Error, Equatable, CustomStringConvertible {
    /// The device isn't a peer this one trusts, or the mesh isn't running.
    case notAPeer
    /// The peer runs a conflux that doesn't offer its files.
    case notOffered
    /// The peer answered with an error.
    case refused(status: Int, message: String)
    /// The peer's file isn't the one listed any more: list again.
    case changed
    /// The copy's SHA-256 isn't the one listed. It was thrown away.
    case corrupt
    /// The connection failed. Pulling again resumes.
    case interrupted(String)

    public var description: String {
        switch self {
        case .notAPeer: "that device isn't a peer of this one"
        case .notOffered: "that device's conflux doesn't offer its model files; update it"
        case .refused(let status, let message): "the peer refused: \(message) (\(status))"
        case .changed: "the file on the peer has changed since it was listed"
        case .corrupt: "the copy didn't match the peer's file, and was thrown away"
        case .interrupted(let why): "the transfer stopped: \(why)"
        }
    }
}

/// How far a pull has got.
public struct PullProgress: Sendable, Equatable {
    /// Bytes on disk, from this pull and any it resumed.
    public var received: Int64
    public var total: Int64
    /// Over the last few seconds. Nil until there's enough to measure.
    public var bytesPerSecond: Double?

    public init(received: Int64, total: Int64, bytesPerSecond: Double? = nil) {
        self.received = received
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double { total > 0 ? Double(received) / Double(total) : 1 }

    /// At the measured rate.
    public var secondsLeft: Double? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, total - received)) / bytesPerSecond
    }
}

/// Lists and copies the files a peer's host serves, over the link to it
/// (`HostService`, `/conflux/0/files`).
///
/// A pull writes to a `.partial` file, hashing as it goes, and renames it
/// once the SHA-256 matches the listing. Stopped, by cancelling or by a lost
/// connection, it keeps the partial file, and the next pull of the same file
/// asks for the rest with `Range`, and `If-Range` naming the version it has
/// part of, so a file that changed on the peer isn't spliced onto the old.
public struct PeerFiles: Sendable {
    let link: any PeerLink

    init(link: any PeerLink) {
        self.link = link
    }

    /// The extended attribute on a partial file naming the SHA-256 of the
    /// file it's part of.
    static let versionAttribute = "conflux.sha256"
    /// The longest a pull waits for the next bytes before giving up.
    static let idleTimeout: TimeInterval = 60

    public func list() async throws -> PeerFileList {
        let base = try await url()
        // A host still hashing its model answers once it's done: minutes,
        // for a large model on a slow disk.
        let request = URLRequest(url: base.appending(path: HostProtocol.filesPath),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        let session = URLSession(configuration: Self.configuration)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            link.reconnect()
            throw PeerFilesError.interrupted(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 { throw PeerFilesError.notOffered }
            throw PeerFilesError.refused(status: status, message: Self.message(in: data))
        }
        return try JSONDecoder().decode(PeerFileList.self, from: data)
    }

    /// Copies `file` to `destination`, through `partial`, replacing anything
    /// at `destination`. Resumes a partial file left by an earlier pull of
    /// the same file. `progress` is called a few times a second, on no
    /// particular thread.
    public func pull(_ file: PeerFile, to destination: URL, partial: URL,
                     progress: @escaping @Sendable (PullProgress) -> Void = { _ in }) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Hashing what's there can take seconds, for gigabytes.
        var (hasher, have) = try await Blocking.run { try Self.resume(partial, for: file) }
        progress(PullProgress(received: have, total: file.size))
        if have < file.size {
            let base = try await url()
            var request = URLRequest(url: base.appending(path: HostProtocol.filesPath + "/" + file.role.rawValue),
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: Self.idleTimeout)
            if have > 0 {
                request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
                request.setValue("\"\(file.sha256)\"", forHTTPHeaderField: "If-Range")
            }
            let transfer = try Transfer(file: file, partial: partial, hasher: hasher, have: have, progress: progress)
            do {
                (hasher, have) = try await transfer.run(request)
            } catch let error as PeerFilesError {
                if case .interrupted = error { link.reconnect() }
                throw error
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard have == file.size, digest == file.sha256 else {
            try? manager.removeItem(at: partial)
            throw PeerFilesError.corrupt
        }
        removexattr(partial.path, Self.versionAttribute, 0)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: partial, to: destination)
    }

    private func url() async throws -> URL {
        do {
            return try await link.url()
        } catch {
            throw PeerFilesError.interrupted("can't reach the peer: \(error)")
        }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = idleTimeout
        // A relayed pull of a large model can take hours.
        configuration.timeoutIntervalForResource = 24 * 3600
        return configuration
    }

    static func message(in data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "no reason given"
    }

    /// What's already in `partial`: its bytes hashed, if they're the start
    /// of `file`. A partial file of some other version, or longer than the
    /// file, is thrown away.
    static func resume(_ partial: URL, for file: PeerFile) throws -> (SHA256, Int64) {
        let manager = FileManager.default
        var hasher = SHA256()
        guard manager.fileExists(atPath: partial.path) else { return (hasher, 0) }
        let size = ((try? manager.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard version(of: partial) == file.sha256, size <= file.size else {
            try manager.removeItem(at: partial)
            return (hasher, 0)
        }
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            read += Int64(chunk.count)
        }
        return (hasher, read)
    }

    static func version(of partial: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(partial.path, versionAttribute, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    static func mark(_ partial: URL, as sha256: String) throws {
        let result = Array(sha256.utf8).withUnsafeBytes { bytes in
            setxattr(partial.path, versionAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// One request for a file's bytes, written to the partial file as they
/// arrive. URLSession calls it on one serial queue, which owns its state.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: PeerFile
    let partial: URL
    let progress: @Sendable (PullProgress) -> Void
    private var hasher: SHA256
    private var have: Int64
    private var handle: FileHandle?
    private var failure: PeerFilesError?
    private var continuation: CheckedContinuation<(SHA256, Int64), any Error>?
    private var task: URLSessionDataTask?
    /// Recent (time, bytes) pairs, for the rate.
    private var samples: [(Date, Int64)] = []
    private var reported = Date.distantPast
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var cancelled = false

    init(file: PeerFile, partial: URL, hasher: SHA256, have: Int64,
         progress: @escaping @Sendable (PullProgress) -> Void) throws {
        self.file = file
        self.partial = partial
        self.hasher = hasher
        self.have = have
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws -> (SHA256, Int64) {
        let session = URLSession(configuration: PeerFiles.configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    self.task = task
                    if lock.withLock({ cancelled }) { task.cancel() }
                    task.resume()
                }
            }
        } onCancel: {
            lock.withLock { cancelled = true }
            queue.addOperation { [self] in task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = .interrupted("not an HTTP answer")
            return completionHandler(.cancel)
        }
        let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        do {
            switch http.statusCode {
            case 206:
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard etag == file.sha256, range.hasPrefix("bytes \(have)-"), range.hasSuffix("/\(file.size)") else {
                    throw PeerFilesError.changed
                }
            case 200:
                // The whole file: the peer has a new version, or ignored the
                // range. Only the version listed will do.
                guard etag == file.sha256, http.expectedContentLength == file.size else { throw PeerFilesError.changed }
                hasher = SHA256()
                have = 0
                try? FileManager.default.removeItem(at: partial)
            case 404:
                throw PeerFilesError.notOffered
            case 412, 416:
                throw PeerFilesError.changed
            default:
                throw PeerFilesError.refused(status: http.statusCode, message: HTTPURLResponse.localizedString(
                    forStatusCode: http.statusCode))
            }
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                    throw PeerFilesError.interrupted("can't write \(partial.lastPathComponent)")
                }
            }
            try PeerFiles.mark(partial, as: file.sha256)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(have))
            try handle.seekToEnd()
            self.handle = handle
            samples = [(Date(), have)]
            completionHandler(.allow)
        } catch {
            failure = error as? PeerFilesError ?? .interrupted(error.localizedDescription)
            if failure == .changed { try? FileManager.default.removeItem(at: partial) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        guard have + Int64(data.count) <= file.size else {
            failure = .corrupt
            return dataTask.cancel()
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .interrupted("can't write \(partial.lastPathComponent): \(error.localizedDescription)")
            return dataTask.cancel()
        }
        hasher.update(data: data)
        have += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(reported) >= 0.25 || have == file.size {
            reported = now
            samples.append((now, have))
            samples.removeAll { now.timeIntervalSince($0.0) > 5 }
            var rate: Double?
            if let first = samples.first, now.timeIntervalSince(first.0) >= 0.5 {
                rate = Double(have - first.1) / now.timeIntervalSince(first.0)
            }
            progress(PullProgress(received: have, total: file.size, bytesPerSecond: rate))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        if let failure {
            if failure == .corrupt { try? FileManager.default.removeItem(at: partial) }
            continuation?.resume(throwing: failure)
        } else if lock.withLock({ cancelled }) {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: PeerFilesError.interrupted(error.localizedDescription))
        } else if have != file.size {
            continuation?.resume(throwing: PeerFilesError.interrupted("the peer sent \(have) of \(file.size) bytes"))
        } else {
            continuation?.resume(returning: (hasher, have))
        }
    }
}
