import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import ConfluxCore

/// Runs file and socket work off Swift's cooperative pool. Tests run in
/// parallel on its few threads, and work that blocks one holds up every
/// other test's tasks, the servers they talk to included.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Blocking.run(work)
}

/// A file of random bytes, generated for the test: never a model's weights.
private func generatedFile(_ size: Int, named name: String = "model.gguf") async throws -> URL {
    try await blocking {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conflux-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data(count: size)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        guard status == errSecSuccess else { throw POSIXError(.EIO) }
        let url = directory.appending(path: name)
        try bytes.write(to: url)
        return url
    }
}

private func sha256(_ url: URL) async throws -> String {
    try await blocking { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
}

private func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
}

/// A host service offering `files`, on loopback, recording the `Range` of
/// each file request.
private final class FileHost: @unchecked Sendable {
    let service: HostService
    private(set) var server: HTTPServer
    private(set) var base: URL
    private let lock = NSLock()
    private var seen: [String?] = []

    var ranges: [String?] { lock.withLock { seen } }

    init(files: [PeerFile.Role: String], hostID: String? = nil, scheduler: Scheduler? = nil) async throws {
        let scheduler = if let scheduler { scheduler } else { await Scheduler.with([]) }
        service = HostService(scheduler: scheduler, hostID: hostID, files: files)
        (server, base) = (HTTPServer { _ in HTTPResponse(status: 500) }, URL(string: "http://127.0.0.1")!)
        try await restart()
    }

    /// A new server for the same service, as after the connection was cut.
    func restart() async throws {
        server.stop()
        let service = self.service
        server = HTTPServer(onlyFromThisProcess: true) { [weak self] request in
            if request.path.hasPrefix(HostProtocol.filesPath + "/") {
                self?.lock.withLock { self?.seen.append(request.header("Range")) }
            }
            return await service.handle(request)
        }
        base = URL(string: "http://127.0.0.1:\(try await server.start(port: 0))")!
    }

    var files: PeerFiles { PeerFiles(link: FixedLink(base: base)) }
}

@Suite struct RangeTests {
    @Test func parsesOneRange() {
        #expect(RangeRequest.parse(nil, size: 100) == .whole)
        #expect(RangeRequest.parse("bytes=0-", size: 100) == .part(offset: 0, length: 100))
        #expect(RangeRequest.parse("bytes=40-", size: 100) == .part(offset: 40, length: 60))
        #expect(RangeRequest.parse("bytes=10-19", size: 100) == .part(offset: 10, length: 10))
        #expect(RangeRequest.parse("bytes=99-99", size: 100) == .part(offset: 99, length: 1))
        // Past the end is cut to the end.
        #expect(RangeRequest.parse("bytes=90-500", size: 100) == .part(offset: 90, length: 10))
        #expect(RangeRequest.parse(" Bytes=5-6 ", size: 100) == .part(offset: 5, length: 2))
        #expect(RangeRequest.parse("bytes=100-", size: 100) == .unsatisfiable)
        #expect(RangeRequest.parse("bytes=0-", size: 0) == .unsatisfiable)
    }

    /// Ranges it doesn't serve are ignored, and the whole file sent.
    @Test func ignoresOtherRanges() {
        for header in ["bytes=-10", "bytes=0-1,5-6", "bytes=5-3", "bytes=a-", "bytes=1-b", "items=0-1", "bytes=",
                       "bytes=--1", "bytes=+1-"] {
            #expect(RangeRequest.parse(header, size: 100) == .whole, "\(header)")
        }
    }

    @Test func statuses() {
        let etag = String(repeating: "ab", count: 32)
        func answer(_ headers: [(name: String, value: String)]) -> HTTPResponse {
            .file(at: "/nowhere", size: 1000, etag: etag, for: HTTPRequest(method: "GET", path: "/", headers: headers))
        }
        let whole = answer([])
        #expect(whole.status == 200)
        #expect(whole.file == HTTPResponse.FileBody(path: "/nowhere", offset: 0, length: 1000))
        #expect(whole.header("ETag") == "\"\(etag)\"")
        #expect(whole.header("Accept-Ranges") == "bytes")

        let part = answer([("Range", "bytes=200-")])
        #expect(part.status == 206)
        #expect(part.file == HTTPResponse.FileBody(path: "/nowhere", offset: 200, length: 800))
        #expect(part.header("Content-Range") == "bytes 200-999/1000")

        let past = answer([("Range", "bytes=1000-")])
        #expect(past.status == 416)
        #expect(past.file == nil)
        #expect(past.header("Content-Range") == "bytes */1000")

        // If-Range naming this version gets the range; another, the whole file.
        #expect(answer([("Range", "bytes=200-"), ("If-Range", "\"\(etag)\"")]).status == 206)
        let changed = answer([("Range", "bytes=200-"), ("If-Range", "\"\(String(repeating: "cd", count: 32))\"")])
        #expect(changed.status == 200)
        #expect(changed.file?.length == 1000)
        #expect(answer([("Range", "bytes=200-"), ("If-Range", "Wed, 21 Oct 2015 07:28:00 GMT")]).status == 200)

        #expect(answer([("If-Match", "\"\(String(repeating: "cd", count: 32))\"")]).status == 412)
        #expect(answer([("If-Match", "\"x\", \"\(etag)\"")]).status == 200)
        #expect(answer([("If-Match", "*")]).status == 200)
    }

    /// A file body's head says how long it is, and carries none of it.
    @Test func aFileBodySendsTheHeadAlone() {
        let response = HTTPResponse(status: 206, headers: [("Content-Type", "application/octet-stream")],
                                    file: HTTPResponse.FileBody(path: "/nowhere", offset: 10, length: 5000))
        let head = String(decoding: response.serialized(keepAlive: true), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(head.contains("Content-Length: 5000\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        #expect(HTTPResponse.reason(412) == "Precondition Failed")
        #expect(HTTPResponse.reason(416) == "Range Not Satisfiable")
    }
}

@Suite struct FileStreamingTests {
    /// The whole file and a range of it, through the server, byte for byte.
    @Test func streamsAFile() async throws {
        let file = try await generatedFile(12 << 20 + 12_345)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let total = size(file)
        let server = HTTPServer { request in
            .file(at: file.path, size: total, etag: "v1", for: request)
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/file")!
        let session = URLSession(configuration: .ephemeral)

        let (whole, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(whole == (try await blocking { try Data(contentsOf: file) }))

        var request = URLRequest(url: url)
        request.setValue("bytes=5000000-5999999", forHTTPHeaderField: "Range")
        let (part, partResponse) = try await session.data(for: request)
        #expect((partResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(part == (try await blocking { try Data(contentsOf: file) }).subdata(in: 5_000_000..<6_000_000))

        // The connection is still good for another request.
        let (again, _) = try await session.data(from: url)
        #expect(again.count == Int(total))
    }

    /// A client that reads nothing holds the server to what the sockets
    /// buffer, not the file; one that closes stops it.
    @Test func neverHoldsTheWholeFile() async throws {
        let file = try await generatedFile(64 << 20)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let total = size(file)
        let server = HTTPServer { request in
            .file(at: file.path, size: total, etag: "v1", for: request)
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }

        // A plain socket, which blocks: off the cooperative pool, where the
        // server's own tasks run.
        let (socket, first) = try await blocking { () -> (Int32, Int) in
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { return (socket, -1) }
            var small: Int32 = 64 << 10
            setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return (socket, -1) }
            let request = Array("GET /file HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            guard write(socket, request, request.count) == request.count else { return (socket, -1) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            return (socket, read(socket, &buffer, buffer.count))
        }
        #expect(socket >= 0)
        #expect(first > 0)

        // Reading nothing more, the server stops reading the file.
        try await Task.sleep(for: .milliseconds(500))
        let stalled = server.fileBytesRead
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.fileBytesRead == stalled)
        #expect(stalled < total / 4, "read \(stalled) of \(total) bytes for a client that read 4 KB")

        // Closing stops the stream: it reads no more.
        close(socket)
        try await Task.sleep(for: .milliseconds(500))
        let closed = server.fileBytesRead
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.fileBytesRead == closed)
        #expect(closed < total)
    }
}

@Suite struct HostFilesTests {
    /// The list names the files, with sizes and SHA-256, and the model they
    /// serve as.
    @Test func listsWhatItServes() async throws {
        let model = try await generatedFile(3 << 20, named: "Tiny-Model-Q8_0.gguf")
        let projector = try await generatedFile(1 << 20, named: "mmproj-Tiny-Model-Q8_0.gguf")
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: projector.deletingLastPathComponent())
        }
        let fake = FakeHost(id: "local")
        let host = try await FileHost(files: [.model: model.path, .projector: projector.path], hostID: "local",
                                      scheduler: await Scheduler.with([fake]))
        defer { host.server.stop() }
        let list = try await host.files.list()
        #expect(list.model == PeerFile(role: .model, name: "Tiny-Model-Q8_0.gguf", size: 3 << 20,
                                       sha256: try await sha256(model)))
        #expect(list.projector == PeerFile(role: .projector, name: "mmproj-Tiny-Model-Q8_0.gguf", size: 1 << 20,
                                           sha256: try await sha256(projector)))
        #expect(list.size == 4 << 20)
        let served = await fake.model
        #expect(list.modelID == served?.id)
        #expect(list.fingerprint == served?.fingerprint)
    }

    /// Nothing but its own files, by role: no path from a request.
    @Test func refusesAnythingElse() async throws {
        let model = try await generatedFile(1 << 20)
        defer { try? FileManager.default.removeItem(at: model.deletingLastPathComponent()) }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let session = URLSession(configuration: .ephemeral)
        for name in ["projector", "weights", "..", "../model", "model/", "model/x", "%2E%2E", "MODEL",
                     String(model.path.dropFirst())] {
            let url = URL(string: host.base.absoluteString + HostProtocol.filesPath + "/" + name)!
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 404, "\(name)")
        }
        var post = URLRequest(url: host.base.appending(path: HostProtocol.filesPath + "/model"))
        post.httpMethod = "POST"
        let (_, response) = try await session.data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        let (_, model200) = try await session.data(from: host.base.appending(path: HostProtocol.filesPath + "/model"))
        #expect((model200 as? HTTPURLResponse)?.statusCode == 200)
    }

    /// A device serving no model file lists nothing, and sends nothing.
    @Test func noModelNoFiles() async throws {
        let host = try await FileHost(files: [:])
        defer { host.server.stop() }
        #expect(try await host.files.list() == PeerFileList())
        let file = PeerFile(role: .model, name: "x.gguf", size: 10, sha256: String(repeating: "0", count: 64))
        let directory = FileManager.default.temporaryDirectory.appending(path: "conflux-pull-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: PeerFilesError.notOffered) {
            try await host.files.pull(file, to: directory.appending(path: "x.gguf"),
                                      partial: directory.appending(path: "x.gguf.partial"))
        }
    }

    /// A peer from before files were offered answers 404 to the list.
    @Test func anOlderPeerOffersNothing() async throws {
        let old = HTTPServer(onlyFromThisProcess: true) { request in
            Gateway.error(404, "no such endpoint: \(request.path)", type: "invalid_request_error")
        }
        let base = URL(string: "http://127.0.0.1:\(try await old.start(port: 0))")!
        defer { old.stop() }
        await #expect(throws: PeerFilesError.notOffered) {
            try await PeerFiles(link: FixedLink(base: base)).list()
        }
    }
}

@Suite struct PullTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "conflux-pull-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pullsAndVerifies() async throws {
        let model = try await generatedFile(5 << 20 + 7)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let list = try await host.files.list()
        let file = try #require(list.model)
        let destination = into.appending(path: file.name), partial = into.appending(path: file.name + ".partial")
        let last = Last()
        try await host.files.pull(file, to: destination, partial: partial) { last.set($0) }
        #expect(try await sha256(destination) == file.sha256)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(last.value?.received == file.size)
        #expect(last.value?.fraction == 1)
        #expect(host.ranges == [nil])
    }

    /// The connection is cut partway: the partial file stays, and the next
    /// pull asks for the rest.
    @Test func resumesAfterACut() async throws {
        let model = try await generatedFile(32 << 20)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let file = try #require(try await host.files.list().model)
        let destination = into.appending(path: file.name), partial = into.appending(path: file.name + ".partial")
        let server = host.server
        let cut = Once()
        await #expect(throws: PeerFilesError.self) {
            try await host.files.pull(file, to: destination, partial: partial) { progress in
                if progress.received > 0 { cut.run { server.stop() } }
            }
        }
        let kept = size(partial)
        #expect(kept > 0 && kept < file.size, "kept \(kept) of \(file.size)")
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        try await host.restart()
        try await host.files.pull(file, to: destination, partial: partial)
        #expect(try await sha256(destination) == file.sha256)
        #expect(host.ranges == [nil, "bytes=\(kept)-"])
    }

    /// Stopped by cancelling, the same.
    @Test func resumesAfterStopping() async throws {
        let model = try await generatedFile(32 << 20)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let files = host.files
        let file = try #require(try await files.list().model)
        let destination = into.appending(path: file.name), partial = into.appending(path: file.name + ".partial")
        let started = AsyncStream.makeStream(of: Void.self)
        let pull = Task {
            try await files.pull(file, to: destination, partial: partial) { progress in
                // Slow, so it's still going when stopped.
                if progress.received > 0 { started.continuation.yield() }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        for await _ in started.stream { break }
        pull.cancel()
        await #expect(throws: CancellationError.self) { try await pull.value }
        let kept = size(partial)
        #expect(kept > 0 && kept < file.size, "kept \(kept) of \(file.size)")

        try await files.pull(file, to: destination, partial: partial)
        #expect(try await sha256(destination) == file.sha256)
        #expect(host.ranges.last == "bytes=\(kept)-")
    }

    /// The file changed on the host since the partial was written: If-Range
    /// gets the whole new file, which the client refuses as not the one
    /// listed, and throws the partial away. Listing again pulls the new one
    /// from the start.
    @Test func aChangedFileStartsOver() async throws {
        let model = try await generatedFile(4 << 20)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let old = try #require(try await host.files.list().model)
        let destination = into.appending(path: old.name), partial = into.appending(path: old.name + ".partial")
        // A partial file of the old version, as a cut pull leaves it.
        try (try Data(contentsOf: model)).prefix(1 << 20).write(to: partial)
        try PeerFiles.mark(partial, as: old.sha256)

        // The host's file changes: other bytes, and a later modification.
        var replacement = try Data(contentsOf: try await generatedFile(4 << 20))
        replacement[0] ^= 0xff
        try replacement.write(to: model)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: model.path)

        await #expect(throws: PeerFilesError.changed) {
            try await host.files.pull(old, to: destination, partial: partial)
        }
        #expect(host.ranges == ["bytes=\(1 << 20)-"])
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        let new = try #require(try await host.files.list().model)
        #expect(new.sha256 != old.sha256)
        try await host.files.pull(new, to: destination, partial: partial)
        #expect(try await sha256(destination) == new.sha256)
        #expect(host.ranges.last == .some(nil))
    }

    /// A partial file left from another version is not resumed.
    @Test func aPartialOfAnotherVersionIsDiscarded() async throws {
        let model = try await generatedFile(2 << 20)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        let file = try #require(try await host.files.list().model)
        let destination = into.appending(path: file.name), partial = into.appending(path: file.name + ".partial")
        try Data(repeating: 7, count: 1000).write(to: partial)
        try PeerFiles.mark(partial, as: String(repeating: "0", count: 64))
        try await host.files.pull(file, to: destination, partial: partial)
        #expect(try await sha256(destination) == file.sha256)
        #expect(host.ranges == [nil])
    }

    /// A listing that doesn't match the bytes: the copy is thrown away.
    @Test func aWrongHashIsRefused() async throws {
        let model = try await generatedFile(1 << 20)
        let into = try directory()
        defer {
            try? FileManager.default.removeItem(at: model.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: into)
        }
        let host = try await FileHost(files: [.model: model.path])
        defer { host.server.stop() }
        var file = try #require(try await host.files.list().model)
        // A partial file already complete, but not of this file's bytes.
        let destination = into.appending(path: file.name), partial = into.appending(path: file.name + ".partial")
        file.sha256 = String(repeating: "1", count: 64)
        try Data(repeating: 1, count: Int(file.size)).write(to: partial)
        try PeerFiles.mark(partial, as: file.sha256)
        await #expect(throws: PeerFilesError.corrupt) {
            try await host.files.pull(file, to: destination, partial: partial)
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(host.ranges.isEmpty)
    }

    @Test func progressMeasuresTheRate() {
        let progress = PullProgress(received: 25, total: 125, bytesPerSecond: 10)
        #expect(progress.fraction == 0.2)
        #expect(progress.secondsLeft == 10)
        #expect(PullProgress(received: 0, total: 10).secondsLeft == nil)
    }
}

private final class Last: @unchecked Sendable {
    private let lock = NSLock()
    private var last: PullProgress?
    func set(_ progress: PullProgress) { lock.withLock { last = progress } }
    var value: PullProgress? { lock.withLock { last } }
}
