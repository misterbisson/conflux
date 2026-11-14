import Foundation

/// Everything one device runs, as saved between launches.
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
    /// Apple's on-device model, served alongside `host`'s.
    public var appleModel: AppleModelSettings
    /// Whether this device runs a gateway for clients. An iPad doesn't: it
    /// serves its model to the Macs' gateways, and uses nobody's host
    /// (docs/plan.md, Phase 3).
    public var gateway: Bool

    public init(host: ModelConfig? = nil, port: UInt16 = 8090, requireToken: Bool = true, peers: [String] = [],
                iCloudKeychain: Bool = true, listedID: String? = nil,
                appleModel: AppleModelSettings = AppleModelSettings(), gateway: Bool = true) {
        self.host = host
        self.port = port
        self.requireToken = requireToken
        self.peers = peers
        self.iCloudKeychain = iCloudKeychain
        self.listedID = listedID
        self.appleModel = appleModel
        self.gateway = gateway
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
        appleModel = try values.decodeIfPresent(AppleModelSettings.self, forKey: .appleModel) ?? AppleModelSettings()
        gateway = try values.decodeIfPresent(Bool.self, forKey: .gateway) ?? true
    }
}

/// Whether to serve Apple's on-device model, and how (`AppleModelHost`).
public struct AppleModelSettings: Sendable, Equatable, Codable {
    /// Off until the owner turns it on.
    public var enabled: Bool
    public var slots: Int
    public var selfCheck: Bool

    public init(enabled: Bool = false, slots: Int = AppleModelHost.defaultSlots, selfCheck: Bool = true) {
        self.enabled = enabled
        self.slots = slots
        self.selfCheck = selfCheck
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

/// A device's gateway and its own hosts, started and stopped together. On an
/// iPad, its hosts alone.
public final class ConfluxNode: @unchecked Sendable {
    public let scheduler: Scheduler
    private let lock = NSLock()
    private var server: HTTPServer?
    /// The model file this device serves, with llama.cpp.
    private var host: (any ManagedHost)?
    /// Apple's on-device model, alongside it.
    private var apple: AppleModelHost?
    /// Each local host's resource monitor, by host ID.
    private var monitors: [String: ResourceMonitor] = [:]
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
    /// Whether this node uses peers' hosts: only with a gateway to send them
    /// work.
    private var usesPeers = true
    /// How often a running node reads the directory. The keychain sends no
    /// notice of changes, so it asks.
    static let directoryInterval: Duration = .seconds(10)

    /// The scheduler's IDs for this device's hosts.
    public static let localHostID = "local"
    public static let appleHostID = "apple"

    public init(scheduler: Scheduler = Scheduler()) {
        self.scheduler = scheduler
    }

    public var port: UInt16? { lock.withLock { boundPort } }

    /// Starts the gateway first, so clients get answers ("starting") while the
    /// model loads, then the host, then the mesh if there are peers. Returns
    /// the gateway's port, or 0 without a gateway. A mesh that can't start
    /// leaves the gateway and host running, and says why in `meshProblem`.
    ///
    /// Peers are the hand-added ones and, with a `directory` and
    /// `settings.iCloudKeychain`, every other device listed there. The
    /// directory is read again every few seconds, and the mesh follows it.
    @discardableResult
    public func start(_ settings: NodeSettings, identity: @autoclosure () throws -> DeviceIdentity = try .load(),
                      directory: (any DeviceDirectory)? = nil,
                      tokenURL: URL = TokenStore.defaultURL) async throws -> UInt16 {
        await stop()
        var port: UInt16 = 0
        if settings.gateway {
            let token = settings.requireToken ? try TokenStore.token(at: tokenURL) : nil
            let gateway = Gateway(scheduler: scheduler, token: token)
            let server = HTTPServer { request in await gateway.handle(request) }
            port = try await server.start(port: settings.port)
            lock.withLock {
                self.server = server
                boundPort = port
            }
        }
        lock.withLock { usesPeers = settings.gateway }
        await scheduler.startRefreshing()

        // With no slots, a host that can't change its slots isn't started:
        // there'd be nothing it could do.
        if let config = settings.host, case let host = Self.host(for: config),
           config.slots > 0 || host is any ResizableHost {
            lock.withLock { self.host = host }
            await serve(host)
        }
        if settings.appleModel.enabled {
            let apple = AppleModelHost(id: Self.appleHostID, slots: settings.appleModel.slots,
                                       selfCheck: settings.appleModel.selfCheck)
            lock.withLock { self.apple = apple }
            await serve(apple)
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

    /// Adds a local host to the scheduler, starts it, and holds its slots to
    /// what resource policy allows.
    private func serve(_ host: any LocalHost) async {
        let monitor = ResourceMonitor()
        lock.withLock { monitors[host.id] = monitor }
        await scheduler.add(host)
        let scheduler = self.scheduler
        monitor.start { reading in
            Task { await Self.limit(host, under: reading, in: scheduler) }
        }
        Task { await host.start() }
    }

    /// Holds a host to what resource policy allows of the slots it has now,
    /// or lifts the limit when nothing limits it.
    private static func limit(_ host: any LocalHost, under reading: ResourceReading, in scheduler: Scheduler) async {
        let limit = ResourcePolicy.limit(slots: host.slots, reading: reading)
        await scheduler.setLimit(limit.reason == nil ? nil : limit.slots, reason: limit.reason, for: host.id)
    }

    /// Changes how many requests one of this device's hosts runs at once,
    /// without stopping: its model's (`LlamaHost.resize(to:cancelling:)`),
    /// where none frees the model and leaves requests to peers' hosts, or
    /// Apple's model's. Does nothing without that host, or with a runtime
    /// whose slots can't change, such as `llama-server`.
    public func setSlots(_ slots: Int, cancelling: Bool, for hostID: String = ConfluxNode.localHostID) async {
        let (host, monitor) = lock.withLock { () -> ((any LocalHost)?, ResourceMonitor?) in
            let host = [self.host as (any LocalHost)?, apple].compactMap { $0 }.first { $0.id == hostID }
            return (host, monitors[hostID])
        }
        guard let host = host as? any ResizableHost else { return }
        await host.resize(to: slots, cancelling: cancelling)
        if let monitor { await Self.limit(host, under: monitor.reading, in: scheduler) }
    }

    /// Why this device's model has fewer slots than asked for, when it does.
    public var slotProblem: String? { (lock.withLock { host } as? LlamaHost)?.slotProblem }

    /// The hosts on this device.
    private var localHosts: [any LocalHost] {
        lock.withLock { [host as (any LocalHost)?, apple].compactMap { $0 } }
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
        let (mesh, usesPeers) = lock.withLock { () -> (Mesh?, Bool) in
            self.trusted = trusted
            return (self.mesh, self.usesPeers)
        }
        let current = Set(mesh?.peers ?? [])
        guard Set(wanted) != current || (mesh == nil && !wanted.isEmpty) else { return }
        do {
            if let mesh, current.isSubset(of: wanted) {
                let added = wanted.filter { !current.contains($0) }
                try mesh.allow(added)
                let joined = usesPeers ? added.compactMap { peer in
                    mesh.link(to: peer).map { RemoteHost(endpointID: peer, link: $0) }
                } : []
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
        // This device's host, for peers' gateways. Served without a host
        // too, so peers hear "serves no model" rather than nothing. Peers see
        // one host per device for now: the model file's, or else Apple's
        // model.
        // And the files of the model it serves, the starter model's
        // included, for peers to copy. None for Apple's model.
        var files: [PeerFile.Role: String] = [:]
        if let config = lock.withLock({ host?.config }) {
            files[.model] = config.model
            files[.projector] = config.projector
        }
        let handler = HostService(scheduler: scheduler, hostID: localHosts.first?.id, files: files)
        let service: HTTPServer
        let exposure: Mesh.Exposure
        if let path = Self.hostSocket {
            service = HTTPServer(onlyFromThisProcess: false) { request in await handler.handle(request) }
            try await service.start(socket: path)
            exposure = .socket(path)
        } else {
            service = HTTPServer(onlyFromThisProcess: true) { request in await handler.handle(request) }
            exposure = .port(try await service.start(port: 0))
        }
        lock.withLock { self.service = service }
        let mesh: Mesh
        do {
            mesh = try Mesh(identity: identity, peers: peers, exposing: exposure)
        } catch {
            service.stop()
            lock.withLock { self.service = nil }
            throw error
        }
        let remotes = lock.withLock { usesPeers } ? peers.compactMap { peer in
            mesh.link(to: peer).map { RemoteHost(endpointID: peer, link: $0) }
        } : []
        lock.withLock {
            self.mesh = mesh
            self.remotes = remotes
        }
        for remote in remotes {
            remote.start()
            await scheduler.add(remote)
        }
    }

    /// The Unix socket peers' streams reach the host service through, or nil
    /// for a loopback port.
    ///
    /// On a Mac, a loopback port, and the host service takes connections only
    /// from this process (`ProcessSockets`). iPadOS can't say which process
    /// connected, so there a socket in the app's container, which other apps
    /// can't reach. `CONFLUX_HOST_SOCKET=1` uses the socket on a Mac too, to
    /// test that path.
    static var hostSocket: String? {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["CONFLUX_HOST_SOCKET"] == "1" else { return nil }
        #endif
        return socketPath(in: NSTemporaryDirectory(), pid: getpid())
    }

    /// The longest a socket's path can be, in bytes.
    static let socketPathLimit = 103

    /// A socket in `directory`, one per process so two on one Mac don't
    /// collide. iPadOS's temporary directory, in the app's container, takes
    /// 89 of the 103 bytes a socket's path holds, so there the name is as
    /// short as it can be.
    static func socketPath(in directory: String, pid: Int32) -> String {
        let directory = directory as NSString
        let path = directory.appendingPathComponent("conflux-\(pid).sock")
        guard path.utf8.count > socketPathLimit else { return path }
        return directory.appendingPathComponent("c\(pid)")
    }

    /// Why the mesh isn't running, when there are peers and it should be.
    public var meshProblem: String? { lock.withLock { meshFailure } }

    /// Why the directory couldn't be read, the last time it was asked.
    public var directoryProblem: String? { lock.withLock { directoryFailure } }

    /// The devices the mesh trusts now, and why.
    public var trustedPeers: [TrustedPeer] { lock.withLock { trusted } }

    /// Each peer, and how its connection is carried. A peer's `hostID` is
    /// empty on a node that doesn't use peers' hosts.
    public var peers: [PeerStatus] {
        let (mesh, remotes) = lock.withLock { (self.mesh, self.remotes) }
        guard let mesh else { return [] }
        return mesh.peers.map { peer in
            PeerStatus(endpointID: peer, hostID: remotes.first { $0.endpointID == peer }?.id ?? "",
                       path: mesh.path(to: peer))
        }
    }

    /// The files a peer's host offers: the model it serves and its
    /// projector. The peer is one this device trusts, and the mesh is
    /// running, with or without a host of its own. Takes as long as the peer
    /// takes to hash its files, if it hasn't yet.
    public func files(of peer: String) async throws -> PeerFileList {
        try await peerFiles(peer).list()
    }

    /// Copies one of a peer's files to `destination`, through `partial`,
    /// resuming what an earlier pull left there (`PeerFiles.pull`). Cancel
    /// the task to stop it; the partial file stays, to resume.
    public func pull(_ file: PeerFile, from peer: String, to destination: URL, partial: URL,
                     progress: @escaping @Sendable (PullProgress) -> Void = { _ in }) async throws {
        try await peerFiles(peer).pull(file, to: destination, partial: partial, progress: progress)
    }

    private func peerFiles(_ peer: String) throws -> PeerFiles {
        guard let link = lock.withLock({ mesh })?.link(to: peer) else { throw PeerFilesError.notAPeer }
        return PeerFiles(link: link)
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
        let hosts = localHosts
        let (server, monitors) = lock.withLock { () -> (HTTPServer?, [ResourceMonitor]) in
            defer { self.server = nil; host = nil; apple = nil; self.monitors = [:]; boundPort = nil }
            return (self.server, Array(self.monitors.values))
        }
        for monitor in monitors { monitor.stop() }
        for host in hosts { host.stop() }
        server?.stop()
        await stopMesh()
        lock.withLock {
            meshFailure = nil
            identity = nil
            manual = []
            usesPeers = true
            directory = nil
            listed = []
            directoryFailure = nil
            trusted = []
        }
        await scheduler.stopRefreshing()
        for host in hosts { await scheduler.remove(hostID: host.id) }
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
        for host in localHosts { await scheduler.setIntent(intent, for: host.id) }
    }

    public var logURL: URL? { lock.withLock { host?.logURL } }
}
