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
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Task { await self.serve(connection) }
    }

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        var continued = false
        while true {
            switch HTTPParser.parse(buffer, maxBodyBytes: maxBodyBytes) {
            case .incomplete(let expectsContinue):
                if expectsContinue && !continued {
                    continued = true
                    await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
                }
                guard let more = await receive(on: connection) else {
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
                buffer.removeFirst(consumed)
                continued = false
                let response = await handler(request)
                let keepAlive = request.keepAlive
                await send(response.serialized(keepAlive: keepAlive), on: connection)
                if !keepAlive {
                    connection.cancel()
                    return
                }
            }
        }
    }

    private func receive(on connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
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
