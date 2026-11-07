import Foundation

/// Everything one Mac runs in Phase 1, as saved between launches.
public struct NodeSettings: Sendable, Equatable, Codable {
    /// The model this Mac serves, or nil to serve none.
    public var host: LlamaServerConfig?
    /// The gateway's port on 127.0.0.1.
    public var port: UInt16
    /// Whether clients must send the bearer token. Turning it off lets any
    /// process on this Mac use the gateway.
    public var requireToken: Bool

    public init(host: LlamaServerConfig? = nil, port: UInt16 = 8090, requireToken: Bool = true) {
        self.host = host
        self.port = port
        self.requireToken = requireToken
    }
}

/// A Mac's gateway and its own host, started and stopped together.
public final class ConfluxNode: @unchecked Sendable {
    public let scheduler: Scheduler
    private let lock = NSLock()
    private var server: HTTPServer?
    private var host: LlamaServerHost?
    private var monitor: ResourceMonitor?
    private var boundPort: UInt16?

    public init(scheduler: Scheduler = Scheduler()) {
        self.scheduler = scheduler
    }

    public var port: UInt16? { lock.withLock { boundPort } }

    /// Starts the gateway first, so clients get answers ("starting") while the
    /// model loads, then the host. Returns the gateway's port.
    @discardableResult
    public func start(_ settings: NodeSettings, tokenURL: URL = TokenStore.defaultURL) async throws -> UInt16 {
        await stop()
        let token = settings.requireToken ? try TokenStore.token(at: tokenURL) : nil
        let gateway = Gateway(scheduler: scheduler, token: token)
        let server = HTTPServer { request in await gateway.handle(request) }
        let port = try await server.start(port: settings.port)
        lock.withLock {
            self.server = server
            boundPort = port
        }
        await scheduler.startRefreshing()

        if let config = settings.host {
            let host = LlamaServerHost(config: config)
            let monitor = ResourceMonitor()
            lock.withLock {
                self.host = host
                self.monitor = monitor
            }
            await scheduler.add(host)
            let scheduler = self.scheduler
            monitor.start { reading in
                let limit = ResourcePolicy.limit(slots: config.slots, reading: reading)
                Task { await scheduler.setLimit(limit.slots, reason: limit.reason, for: host.id) }
            }
            Task { await host.start() }
        }
        return port
    }

    public func stop() async {
        let (server, host, monitor) = lock.withLock { () -> (HTTPServer?, LlamaServerHost?, ResourceMonitor?) in
            defer { self.server = nil; self.host = nil; self.monitor = nil; boundPort = nil }
            return (self.server, self.host, self.monitor)
        }
        monitor?.stop()
        host?.stop()
        server?.stop()
        await scheduler.stopRefreshing()
        if let host { await scheduler.remove(hostID: host.id) }
    }

    public func setIntent(_ intent: OwnerIntent) async {
        guard let id = lock.withLock({ host?.id }) else { return }
        await scheduler.setIntent(intent, for: id)
    }

    public var logURL: URL? { lock.withLock { host?.logURL } }
}
