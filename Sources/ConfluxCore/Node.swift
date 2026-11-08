import Foundation

/// Everything one Mac runs, as saved between launches.
public struct NodeSettings: Sendable, Equatable, Codable {
    /// The model this Mac serves, or nil to serve none.
    public var host: ModelConfig?
    /// The gateway's port on 127.0.0.1.
    public var port: UInt16
    /// Whether clients must send the bearer token. Turning it off lets any
    /// process on this Mac use the gateway.
    public var requireToken: Bool
    /// Other devices' endpoint IDs. Each may use this Mac's host, and this
    /// Mac's gateway sends work to theirs. With none, conflux starts no iroh
    /// endpoint and contacts nothing.
    public var peers: [String]

    public init(host: ModelConfig? = nil, port: UInt16 = 8090, requireToken: Bool = true, peers: [String] = []) {
        self.host = host
        self.port = port
        self.requireToken = requireToken
        self.peers = peers
    }

    // Settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(ModelConfig.self, forKey: .host)
        port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? 8090
        requireToken = try values.decodeIfPresent(Bool.self, forKey: .requireToken) ?? true
        peers = try values.decodeIfPresent([String].self, forKey: .peers) ?? []
    }
}

/// A peer as this Mac sees it, for the window.
public struct PeerStatus: Sendable, Equatable, Identifiable {
    public var id: String { endpointID }
    public var endpointID: String
    /// The scheduler's ID for the peer's host.
    public var hostID: String
    public var path: PeerPath
}

/// A Mac's gateway and its own host, started and stopped together.
public final class ConfluxNode: @unchecked Sendable {
    public let scheduler: Scheduler
    private let lock = NSLock()
    private var server: HTTPServer?
    private var host: (any ManagedHost)?
    private var monitor: ResourceMonitor?
    private var boundPort: UInt16?
    private var service: HTTPServer?
    private var mesh: Mesh?
    private var remotes: [RemoteHost] = []
    private var meshFailure: String?

    public init(scheduler: Scheduler = Scheduler()) {
        self.scheduler = scheduler
    }

    public var port: UInt16? { lock.withLock { boundPort } }

    /// Starts the gateway first, so clients get answers ("starting") while the
    /// model loads, then the host, then the mesh if there are peers. Returns
    /// the gateway's port. A mesh that can't start leaves the gateway and
    /// host running, and says why in `meshProblem`.
    @discardableResult
    public func start(_ settings: NodeSettings, identity: @autoclosure () throws -> DeviceIdentity = try .load(),
                      tokenURL: URL = TokenStore.defaultURL) async throws -> UInt16 {
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
            let host: any ManagedHost = switch config.runtime {
            case .inProcess: LlamaHost(config: config)
            case .llamaServer: LlamaServerHost(config: config)
            }
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

        do {
            try await startMesh(settings, identity: identity)
        } catch {
            lock.withLock { meshFailure = "\(error)" }
        }
        return port
    }

    private func startMesh(_ settings: NodeSettings, identity: () throws -> DeviceIdentity) async throws {
        // No peers, no endpoint: conflux contacts nothing, and needs no key.
        guard settings.peers.contains(where: DeviceIdentity.isEndpointID) else { return }
        let identity = try identity()
        let peers = Array(Set(settings.peers.filter {
            DeviceIdentity.isEndpointID($0) && $0 != identity.endpointID
        })).sorted()
        guard !peers.isEmpty else { return }

        // This Mac's host, for peers' gateways. Served without a host too,
        // so peers hear "serves no model" rather than nothing.
        let handler = HostService(scheduler: scheduler, hostID: lock.withLock { host?.id })
        let service = HTTPServer(onlyFromThisProcess: true) { request in await handler.handle(request) }
        let exposed = try await service.start(port: 0)
        lock.withLock { self.service = service }
        let mesh = try Mesh(identity: identity, peers: peers, exposing: exposed)
        let remotes = peers.compactMap { peer in mesh.link(to: peer).map { RemoteHost(endpointID: peer, link: $0) } }
        lock.withLock {
            self.mesh = mesh
            self.remotes = remotes
        }
        for remote in remotes {
            remote.start()
            await scheduler.add(remote)
        }
    }

    /// Why the mesh isn't running, when there are peers and it should be.
    public var meshProblem: String? { lock.withLock { meshFailure } }

    /// Each peer, and how its connection is carried.
    public var peers: [PeerStatus] {
        let (mesh, remotes) = lock.withLock { (self.mesh, self.remotes) }
        guard let mesh else { return [] }
        return remotes.map { PeerStatus(endpointID: $0.endpointID, hostID: $0.id, path: mesh.path(to: $0.endpointID)) }
    }

    /// Devices that tried to connect and weren't peers.
    public var refusedConnections: Int { lock.withLock { mesh }?.refused ?? 0 }

    public func stop() async {
        let (server, host, monitor) = lock.withLock { () -> (HTTPServer?, (any ManagedHost)?, ResourceMonitor?) in
            defer { self.server = nil; self.host = nil; self.monitor = nil; boundPort = nil }
            return (self.server, self.host, self.monitor)
        }
        let (service, mesh, remotes) = lock.withLock { () -> (HTTPServer?, Mesh?, [RemoteHost]) in
            defer { self.service = nil; self.mesh = nil; self.remotes = []; meshFailure = nil }
            return (self.service, self.mesh, self.remotes)
        }
        monitor?.stop()
        host?.stop()
        server?.stop()
        for remote in remotes {
            remote.stop()
            await scheduler.remove(hostID: remote.id)
        }
        service?.stop()
        mesh?.stop()
        await scheduler.stopRefreshing()
        if let host { await scheduler.remove(hostID: host.id) }
    }

    public func setIntent(_ intent: OwnerIntent) async {
        guard let id = lock.withLock({ host?.id }) else { return }
        await scheduler.setIntent(intent, for: id)
    }

    public var logURL: URL? { lock.withLock { host?.logURL } }
}
