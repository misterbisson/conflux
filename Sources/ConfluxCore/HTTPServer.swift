import Foundation
@preconcurrency import Network

/// A small HTTP/1.1 server that listens on loopback, or on a Unix socket.
///
/// It handles one request at a time per connection, with keep-alive, and as
/// many connections at once as clients open. It's enough for an
/// OpenAI-compatible API on 127.0.0.1, and it has no dependencies.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let maxBodyBytes: Int
    /// Accept only connections this process opened (`ProcessSockets`).
    let onlyFromThisProcess: Bool
    private let handler: Handler
    private let queue = DispatchQueue(label: "conflux.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var socketPath: String?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public convenience init(maxBodyBytes: Int = 64 * 1024 * 1024, handler: @escaping Handler) {
        self.init(maxBodyBytes: maxBodyBytes, onlyFromThisProcess: false, handler: handler)
    }

    init(maxBodyBytes: Int = 64 * 1024 * 1024, onlyFromThisProcess: Bool, handler: @escaping Handler) {
        self.maxBodyBytes = maxBodyBytes
        self.onlyFromThisProcess = onlyFromThisProcess
        self.handler = handler
    }

    /// Starts listening on 127.0.0.1. Port 0 picks a free port. Returns the
    /// port actually bound.
    public func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        return try await listen(listener) { $0.port?.rawValue ?? port }
    }

    /// Starts listening on a Unix socket at `path`, replacing a socket left
    /// there by an earlier run. Any process that can reach the path can
    /// connect: in an app's own container, that's this app alone, which is
    /// why the host service listens here on iPadOS, where it can't ask which
    /// process connected (`ProcessSockets`).
    func start(socket path: String) async throws {
        try? FileManager.default.removeItem(atPath: path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        _ = try await listen(listener) { _ in 0 }
        lock.withLock { socketPath = path }
    }

    private func listen(_ listener: NWListener, bound: @escaping @Sendable (NWListener) -> UInt16) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: bound(listener)) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return port
    }

    public func stop() {
        let (listener, connections, path) = lock.withLock {
            defer { self.listener = nil; self.connections = [:]; socketPath = nil }
            return (self.listener, Array(self.connections.values), socketPath)
        }
        listener?.cancel()
        connections.forEach { $0.cancel() }
        if let path { try? FileManager.default.removeItem(atPath: path) }
    }

    private func accept(_ connection: NWConnection) {
        if onlyFromThisProcess {
            guard case .hostPort(_, let port) = connection.endpoint, ProcessSockets.ownsLocalPort(port.rawValue)
            else {
                connection.cancel()
                return
            }
        }
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        let inbox = Inbox(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                inbox.close()
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Task { await self.serve(connection, inbox: inbox) }
    }

    private func serve(_ connection: NWConnection, inbox: Inbox) async {
        var buffer = Data()
        var continued = false
        while true {
            switch HTTPParser.parse(buffer, maxBodyBytes: maxBodyBytes) {
            case .incomplete(let expectsContinue):
                if expectsContinue && !continued {
                    continued = true
                    await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
                }
                guard let more = await inbox.next() else {
                    connection.cancel()
                    return
                }
                buffer.append(more)
            case .failure(let status, let message):
                let response = HTTPResponse.json(status, ["error": ["message": message, "type": "invalid_request_error"]])
                await send(response.serialized(keepAlive: false), on: connection)
                connection.cancel()
                return
            case .request(let request, let consumed):
                buffer = HTTPServer.remainder(of: buffer, after: consumed)
                continued = false
                let response = await handle(request, watching: inbox)
                let keepAlive = request.keepAlive
                await send(response.serialized(keepAlive: keepAlive), on: connection)
                // A client that has closed its side sends nothing more to answer.
                if !keepAlive || inbox.isClosed {
                    connection.cancel()
                    return
                }
            }
        }
    }

    /// Runs the handler, and cancels it if the client closes the connection
    /// first: nobody is left to take the answer, and the work would hold a
    /// slot that requests still waiting could use.
    private func handle(_ request: HTTPRequest, watching inbox: Inbox) async -> HTTPResponse {
        let handler = self.handler
        let task = Task { await handler(request) }
        inbox.whenClosed { task.cancel() }
        defer { inbox.whenClosed(nil) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// What's left of `buffer` after its first `count` bytes, in storage of
    /// its own. `Data.removeFirst` only moves the start forward and keeps
    /// every byte before it, so a keep-alive connection would hold all it
    /// had ever received, gigabytes over a long night of image requests.
    static func remainder(of buffer: Data, after count: Int) -> Data {
        guard count < buffer.count else { return Data() }
        return buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: count)..<buffer.endIndex)
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

/// What a connection has received and not yet handed on, and whether the
/// client has closed it.
///
/// It keeps one receive outstanding, also while a request is being handled,
/// because that's the only way to hear that the client has gone: a client
/// that gives up closes its socket, and the receive completes. Bytes that
/// arrive meanwhile, a pipelined request, are kept for `next()`. Past
/// `ahead` bytes kept, it stops reading until they're taken, so a client
/// can't make the server hold more than that.
final class Inbox: @unchecked Sendable {
    static let ahead = 1 << 20

    private let connection: NWConnection
    private let lock = NSLock()
    private var pending = Data()
    private var closed = false
    private var reading = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var onClose: (@Sendable () -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Whether the client has closed the connection, or it failed.
    var isClosed: Bool { lock.withLock { closed } }

    /// The bytes received since the last call, waiting for some if there are
    /// none yet. Nil once the connection is closed and every byte is taken.
    func next() async -> Data? {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Data?? in
                if !pending.isEmpty {
                    defer { pending = Data() }
                    return .some(pending)
                }
                if closed { return .some(nil) }
                waiter = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
            read()
        }
    }

    /// Calls `action` once the connection closes, at once if it has already.
    /// Nil stops watching.
    func whenClosed(_ action: (@Sendable () -> Void)?) {
        let now = lock.withLock { () -> Bool in
            guard closed else {
                onClose = action
                return false
            }
            onClose = nil
            return action != nil
        }
        if now { action?() }
    }

    /// The connection failed or was cancelled.
    func close() {
        received(nil, ended: true)
    }

    private func read() {
        let start = lock.withLock { () -> Bool in
            guard !reading, !closed, pending.count < Self.ahead else { return false }
            reading = true
            return true
        }
        guard start else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.ahead) { [self] data, _, isComplete, error in
            lock.withLock { reading = false }
            received(data, ended: isComplete || error != nil)
            read()
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        let (waiter, handing, closing) = lock.withLock {
            () -> (CheckedContinuation<Data?, Never>?, Data?, (@Sendable () -> Void)?) in
            if let data, !data.isEmpty { pending.append(data) }
            var closing: (@Sendable () -> Void)?
            if ended && !closed {
                closed = true
                closing = onClose
                onClose = nil
            }
            guard let waiter, !pending.isEmpty || closed else { return (nil, nil, closing) }
            self.waiter = nil
            let handing = pending.isEmpty ? nil : pending
            pending = Data()
            return (waiter, handing, closing)
        }
        waiter?.resume(returning: handing)
        closing?()
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
