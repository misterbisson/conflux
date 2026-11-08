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
    /// Other devices' endpoint IDs, added by hand. Each may use this Mac's
    /// host, and this Mac's gateway sends work to theirs. With none, and none
    /// in the device directory, conflux starts no iroh endpoint and contacts
    /// nothing.
    public var peers: [String]
    /// Whether this Mac lists itself in the device directory, iCloud Keychain,
    /// and trusts the other devices listed there. Only a signed app has a
    /// directory; built from source, peers are added by hand.
    public var iCloudKeychain: Bool
    /// The endpoint ID this Mac last listed in the directory. Its listing gone
    /// while this is set means another device forgot this one.
    public var listedID: String?

    public init(host: ModelConfig? = nil, port: UInt16 = 8090, requireToken: Bool = true, peers: [String] = [],
                iCloudKeychain: Bool = true, listedID: String? = nil) {
        self.host = host
        self.port = port
        self.requireToken = requireToken
        self.peers = peers
        self.iCloudKeychain = iCloudKeychain
        self.listedID = listedID
    }

    // Settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(ModelConfig.self, forKey: .host)
        port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? 8090
        requireToken = try values.decodeIfPresent(Bool.self, forKey: .requireToken) ?? true
        peers = try values.decodeIfPresent([String].self, forKey: .peers) ?? []
        iCloudKeychain = try values.decodeIfPresent(Bool.self, forKey: .iCloudKeychain) ?? true
        listedID = try values.decodeIfPresent(String.self, forKey: .listedID)
    }
}

/// A device this Mac trusts, and why: added by hand, listed in the device
/// directory, or both.
public struct TrustedPeer: Sendable, Equatable, Identifiable {
    public var id: String { endpointID }
    public let endpointID: String
    /// The name it listed itself under, when it's listed.
    public var name: String?
    public var addedByHand: Bool
    public var listed: Bool { name != nil }

    public init(endpointID: String, name: String? = nil, addedByHand: Bool = false) {
        self.endpointID = endpointID
        self.name = name
        self.addedByHand = addedByHand
    }

    /// Hand-added peers and listed devices together, each once, without this
    /// device or anything that isn't an endpoint ID.
    public static func merge(manual: [String], listed: [ListedDevice], this: String?) -> [TrustedPeer] {
        var peers: [String: TrustedPeer] = [:]
        for id in manual where DeviceIdentity.isEndpointID(id) {
            peers[id] = TrustedPeer(endpointID: id, addedByHand: true)
        }
        for device in listed where DeviceIdentity.isEndpointID(device.endpointID) {
            peers[device.endpointID, default: TrustedPeer(endpointID: device.endpointID)].name = device.name
        }
        if let this { peers[this] = nil }
        return peers.values.sorted { $0.endpointID < $1.endpointID }
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
    private var identity: DeviceIdentity?
    private var manual: [String] = []
    private var directory: (any DeviceDirectory)?
    private var listed: [ListedDevice] = []
    private var directoryFailure: String?
    private var trusted: [TrustedPeer] = []
    private var watching: (task: Task<Void, Never>, ticker: Task<Void, Never>, wake: AsyncStream<Void>.Continuation)?
    /// How often a running node reads the directory. The keychain sends no
    /// notice of changes, so it asks.
    static let directoryInterval: Duration = .seconds(10)

    public init(scheduler: Scheduler = Scheduler()) {
        self.scheduler = scheduler
    }

    public var port: UInt16? { lock.withLock { boundPort } }

    /// Starts the gateway first, so clients get answers ("starting") while the
    /// model loads, then the host, then the mesh if there are peers. Returns
    /// the gateway's port. A mesh that can't start leaves the gateway and
    /// host running, and says why in `meshProblem`.
    ///
    /// Peers are the hand-added ones and, with a `directory` and
    /// `settings.iCloudKeychain`, every other device listed there. The
    /// directory is read again every few seconds, and the mesh follows it.
    @discardableResult
    public func start(_ settings: NodeSettings, identity: @autoclosure () throws -> DeviceIdentity = try .load(),
                      directory: (any DeviceDirectory)? = nil,
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
            let host = Self.host(for: config)
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

        let directory = settings.iCloudKeychain ? directory : nil
        let manual = settings.peers.filter(DeviceIdentity.isEndpointID)
        lock.withLock {
            self.directory = directory
            self.manual = manual
        }
        // No peers and no directory, no endpoint: conflux contacts nothing,
        // and needs no key.
        guard directory != nil || !manual.isEmpty else { return port }
        do {
            let identity = try identity()
            lock.withLock { self.identity = identity }
        } catch {
            lock.withLock { meshFailure = "\(error)" }
            return port
        }
        await refreshPeers()
        if directory != nil { watchDirectory() }
        return port
    }

    /// Reads the directory, then grows or restarts the mesh to match. A
    /// directory that can't be read leaves the peers it last gave: an
    /// unreadable list trusts nobody new.
    func refreshPeers() async {
        let (identity, manual, directory) = lock.withLock { (self.identity, self.manual, self.directory) }
        guard let identity else { return }
        if let directory {
            do {
                let listed = try directory.others(than: identity.endpointID)
                lock.withLock {
                    self.listed = listed
                    directoryFailure = nil
                }
            } catch {
                lock.withLock { directoryFailure = "\(error)" }
            }
        }
        let trusted = TrustedPeer.merge(manual: manual, listed: lock.withLock { listed }, this: identity.endpointID)
        await apply(trusted, identity: identity)
    }

    /// Makes the mesh trust exactly `trusted`. Added peers join the running
    /// mesh; a removed one means a new mesh, because apple-iroh can't take an
    /// ID off its allow list or close one peer's connection.
    private func apply(_ trusted: [TrustedPeer], identity: DeviceIdentity) async {
        let wanted = trusted.map(\.endpointID)
        let (mesh, current) = lock.withLock { () -> (Mesh?, Set<String>) in
            self.trusted = trusted
            return (self.mesh, Set(remotes.map(\.endpointID)))
        }
        guard Set(wanted) != current || (mesh == nil && !wanted.isEmpty) else { return }
        do {
            if let mesh, current.isSubset(of: wanted) {
                let added = wanted.filter { !current.contains($0) }
                try mesh.allow(added)
                let joined = added.compactMap { peer in
                    mesh.link(to: peer).map { RemoteHost(endpointID: peer, link: $0) }
                }
                lock.withLock { remotes += joined }
                for remote in joined {
                    remote.start()
                    await scheduler.add(remote)
                }
            } else {
                await stopMesh()
                if !wanted.isEmpty { try await startMesh(peers: wanted, identity: identity) }
            }
            lock.withLock { meshFailure = nil }
        } catch {
            lock.withLock { meshFailure = "\(error)" }
        }
    }

    private func watchDirectory() {
        let (ticks, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.directoryInterval)
                wake.yield()
            }
        }
        let task = Task { [weak self] in
            for await _ in ticks { await self?.refreshPeers() }
        }
        lock.withLock { watching = (task, ticker, wake) }
    }

    /// Reads the directory now rather than at the next tick, after this
    /// device changed it.
    public func refreshSoon() { lock.withLock { watching?.wake }?.yield() }

    private func startMesh(peers: [String], identity: DeviceIdentity) async throws {
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

    /// Why the directory couldn't be read, the last time it was asked.
    public var directoryProblem: String? { lock.withLock { directoryFailure } }

    /// The devices the mesh trusts now, and why.
    public var trustedPeers: [TrustedPeer] { lock.withLock { trusted } }

    /// Each peer, and how its connection is carried.
    public var peers: [PeerStatus] {
        let (mesh, remotes) = lock.withLock { (self.mesh, self.remotes) }
        guard let mesh else { return [] }
        return remotes.map { PeerStatus(endpointID: $0.endpointID, hostID: $0.id, path: mesh.path(to: $0.endpointID)) }
    }

    /// Devices that tried to connect and weren't peers.
    public var refusedConnections: Int { lock.withLock { mesh }?.refused ?? 0 }

    /// The host for a model, by its runtime. iPadOS can't start processes,
    /// so there a `llama-server` setting runs in-process instead.
    static func host(for config: ModelConfig) -> any ManagedHost {
        switch config.runtime {
        case .inProcess:
            return LlamaHost(config: config)
        case .llamaServer:
            #if os(macOS)
            return LlamaServerHost(config: config)
            #else
            return LlamaHost(config: config)
            #endif
        }
    }

    public func stop() async {
        // The watcher changes the mesh, so it stops first.
        if let watching = lock.withLock({ () -> (task: Task<Void, Never>, ticker: Task<Void, Never>,
                                                 wake: AsyncStream<Void>.Continuation)? in
            defer { self.watching = nil }
            return self.watching
        }) {
            watching.ticker.cancel()
            watching.wake.finish()
            await watching.task.value
        }
        let (server, host, monitor) = lock.withLock { () -> (HTTPServer?, (any ManagedHost)?, ResourceMonitor?) in
            defer { self.server = nil; self.host = nil; self.monitor = nil; boundPort = nil }
            return (self.server, self.host, self.monitor)
        }
        monitor?.stop()
        host?.stop()
        server?.stop()
        await stopMesh()
        lock.withLock {
            meshFailure = nil
            identity = nil
            manual = []
            directory = nil
            listed = []
            directoryFailure = nil
            trusted = []
        }
        await scheduler.stopRefreshing()
        if let host { await scheduler.remove(hostID: host.id) }
    }

    private func stopMesh() async {
        let (service, mesh, remotes) = lock.withLock { () -> (HTTPServer?, Mesh?, [RemoteHost]) in
            defer { self.service = nil; self.mesh = nil; self.remotes = [] }
            return (self.service, self.mesh, self.remotes)
        }
        for remote in remotes {
            remote.stop()
            await scheduler.remove(hostID: remote.id)
        }
        service?.stop()
        mesh?.stop()
    }

    public func setIntent(_ intent: OwnerIntent) async {
        guard let id = lock.withLock({ host?.id }) else { return }
        await scheduler.setIntent(intent, for: id)
    }

    public var logURL: URL? { lock.withLock { host?.logURL } }
}
