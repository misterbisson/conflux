import AppKit
import ConfluxCore
import ConfluxUI
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers

struct ConfluxApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Run from the command line, the process starts as a background tool.
        // This makes it an ordinary app with a Dock icon and a window in front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        // One control panel, so one window: no tabs to open a second.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // A window group, not a `Window`: an app whose only scene is a `Window`
    // quits when it closes, which would stop the gateway. This one keeps
    // serving, and the Dock icon brings the window back.
    var body: some Scene {
        WindowGroup("conflux") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            // No File › New Window: a second window would be a copy of this one.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NodeSettings {
        didSet {
            save()
            if settings.host?.model != oldValue.host?.model || settings.host?.projector != oldValue.host?.projector {
                checkFiles()
            }
        }
    }
    /// What's wrong with the chosen model and projector, from their headers:
    /// a model that's a projector, a projector that isn't one or doesn't fit
    /// the model. In the sandbox conflux reads only the files chosen, not
    /// their neighbours, so it can't suggest a projector, but it can say this.
    @Published private(set) var fileProblems: [String] = []
    @Published private(set) var snapshot: SchedulerSnapshot?
    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var intent: OwnerIntent = .serving
    @Published var problem: String?
    @Published private(set) var peers: [PeerStatus] = []
    @Published private(set) var meshProblem: String?
    /// Why this Mac's model has fewer slots than asked for.
    @Published private(set) var slotProblem: String?
    @Published private(set) var refused = 0
    /// Each host's last day by the minute, for the activity chart.
    @Published private(set) var activity: [String: [ActivityMinute]] = [:]
    /// The model each host last served, so the chart can show a model's
    /// hosts after one has left.
    private var hostModels: [String: String] = [:]
    /// Requests waiting at this gateway, the most in each reading.
    @Published private(set) var waiting = TimeSeries(keeping: .highest)
    /// conflux's memory footprint: with the model run in the process, the
    /// model's memory.
    @Published private(set) var memory = TimeSeries()
    /// The Mac's memory pressure, and what resource policy is doing about
    /// it.
    @Published private(set) var memoryStatus: MemoryStatus?
    /// Memory pressure as a level, the highest in each reading.
    @Published private(set) var pressure = TimeSeries(keeping: .highest)
    /// The thermal state as a level, the highest in each reading.
    @Published private(set) var heat = TimeSeries(keeping: .highest)
    /// The Heat tile's Cool down box, and what resource policy is doing.
    @Published private(set) var heatStatus = HeatStatus(box: .off)
    /// This Mac's endpoint ID, for other devices' peer lists.
    let endpointID: String?
    /// iCloud Keychain's device directory. Only a signed app has one: built
    /// from source, peers are added by hand.
    let directory = KeychainDeviceDirectory.forThisApp()
    /// The other devices listed in the directory.
    @Published private(set) var listed: [ListedDevice] = []
    @Published private(set) var directoryProblem: String?
    /// Something about the directory the owner should know, such as this Mac
    /// having been forgotten.
    @Published private(set) var directoryNotice: String?

    let node = ConfluxNode()
    private let access = ModelAccess()
    private var polling: Task<Void, Never>?
    /// The last change of slots sent to the node. Each waits for the one
    /// before, so they arrive in order.
    private var resizing: Task<Void, Never>?
    private var watchingDirectory: Task<Void, Never>?
    /// How often the window reads the directory and refreshes this Mac's
    /// listing. The keychain sends no notice of changes.
    private static let directoryInterval: Duration = .seconds(10)
    private static let key = "settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(NodeSettings.self, from: data) {
            settings = saved
        } else {
            settings = NodeSettings()
        }
        // Made and kept in the keychain the first time. Nothing is contacted
        // until there are peers and the node starts.
        endpointID = try? DeviceIdentity.load().endpointID
        polling = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if let self {
                    let snapshot = await self.node.scheduler.snapshot()
                    self.snapshot = snapshot
                    for host in snapshot.hosts { if let model = host.model?.id { self.hostModels[host.id] = model } }
                    self.peers = self.node.peers
                    self.meshProblem = self.node.meshProblem
                    self.slotProblem = self.node.slotProblem
                    self.refused = self.node.refusedConnections
                    self.waiting.append(Double(snapshot.queued))
                    self.memory.append(Double(ProcessMemory.footprint.now))
                    self.memoryStatus = self.node.memoryStatus
                    if let status = self.memoryStatus { self.pressure.append(Double(status.level)) }
                    self.heat.append(Double(Thermal.level))
                    self.heatStatus = self.node.heatStatus
                    // A day of minutes changes once a minute at most, and
                    // the chart's latest bar fills in within a few seconds.
                    if tick % 5 == 0 {
                        self.activity = await self.node.scheduler.activity(since: Date().addingTimeInterval(-86400))
                    }
                    tick += 1
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if directory != nil {
            watchingDirectory = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.syncDirectory()
                    try? await Task.sleep(for: Self.directoryInterval)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [node] _ in
            // Don't leave llama-server running after the app quits.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await node.stop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
        checkFiles()
    }

    /// Reads the chosen files' headers, off the main thread, and says what's
    /// wrong with them in `fileProblems`.
    func checkFiles() {
        guard let host = settings.host, !host.model.isEmpty else {
            fileProblems = []
            return
        }
        let borrowed = ([host.model] + (host.projector.map { [$0] } ?? [])).map(access.borrow)
        Task {
            let problems = await Task.detached {
                Projectors.problems(model: GGUFFile(borrowed[0].url),
                                    projector: borrowed.count > 1 ? GGUFFile(borrowed[1].url) : nil)
            }.value
            access.giveBack(borrowed)
            // Chosen again meanwhile: that check says what's wrong.
            guard settings.host?.model == host.model, settings.host?.projector == host.projector else { return }
            fileProblems = problems
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// This Mac's own host, for its model file.
    var host: HostSnapshot? { snapshot?.hosts.first { $0.id == ConfluxNode.localHostID } }

    /// This Mac's host for Apple's on-device model.
    var appleHost: HostSnapshot? { snapshot?.hosts.first { $0.id == ConfluxNode.appleHostID } }

    func peerHost(_ peer: PeerStatus) -> HostSnapshot? { snapshot?.hosts.first { $0.id == peer.hostID } }

    /// Every host a peer serves, the one it answers for by default first.
    func peerHosts(_ peer: PeerStatus) -> [HostSnapshot] {
        peer.hostIDs.compactMap { id in snapshot?.hosts.first { $0.id == id } }
    }

    /// The name a peer's host goes by: the trusted peer's name, when it has
    /// one. Nil for this Mac's hosts, and for peers without a name.
    func peerName(of host: HostSnapshot) -> String? {
        guard let endpointID = peers.first(where: { $0.hostIDs.contains(host.id) })?.endpointID else { return nil }
        return trusted.first { $0.endpointID == endpointID }?.name
    }

    /// Every host with activity, this Mac's first, then Apple's model, then
    /// peers, so each keeps its place and its colour in the chart.
    var activitySeries: [ActivitySeries] {
        var ids = Set(activity.keys).union(snapshot?.hosts.map(\.id) ?? [])
        let first = [ConfluxNode.localHostID, ConfluxNode.appleHostID].filter { ids.contains($0) }
        ids.subtract(first)
        return (first + ids.sorted()).map { id in
            ActivitySeries(id: id, name: hostName(id), minutes: activity[id] ?? [], model: hostModels[id],
                           typicalSeconds: snapshot?.hosts.first { $0.id == id }?.typicalSeconds)
        }
    }

    /// What the chart calls a host: by its device's name for a peer, even
    /// one that has left.
    func hostName(_ id: String) -> String {
        switch id {
        case ConfluxNode.localHostID: return "This Mac"
        case ConfluxNode.appleHostID: return "Apple's model"
        default:
            let other = RemoteHost.hostOnPeer(in: id)
            let peer = trusted.first { RemoteHost.id($0.endpointID, other) == id }
            let name = peer?.name ?? String(id.dropFirst("peer-".count).prefix(10)) + "…"
            return other.map { "\(name), \(Self.otherHostName($0))" } ?? name
        }
    }

    /// What a peer's host after its first is called, by its ID on the peer.
    static func otherHostName(_ hostOnPeer: String) -> String {
        hostOnPeer == ConfluxNode.appleHostID ? "Apple's model" : hostOnPeer
    }

    /// The model the app ships, served until the person chooses one. Built
    /// from source, there's none.
    let starter = StarterModel.files()

    /// Whether this Mac serves the starter model: none is chosen, and the app
    /// has one.
    var servesStarter: Bool { starter != nil && (settings.host?.model.isEmpty ?? true) }

    var canStart: Bool {
        (settings.servesModelFile && (!(settings.host?.model.isEmpty ?? true) || starter != nil))
            || settings.appleModel.enabled || !trusted.isEmpty
    }

    /// Every device this Mac trusts: added by hand, listed in iCloud
    /// Keychain, or both.
    var trusted: [TrustedPeer] {
        TrustedPeer.merge(manual: settings.peers, listed: settings.iCloudKeychain ? listed : [], this: endpointID)
    }

    /// The name this Mac lists itself under: its computer name, from Sharing
    /// settings.
    private var deviceName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    }

    /// Keeps this Mac listed, and reads the other devices. A Mac whose
    /// listing another device removed stays out, and stops trusting the
    /// directory, until its owner turns it on again.
    func syncDirectory() async {
        guard let directory, let endpointID, settings.iCloudKeychain else {
            listed = []
            return
        }
        let (name, before) = (deviceName, settings.listedID)
        let result = await Task.detached { () -> Result<(Membership, [ListedDevice]), any Error> in
            Result {
                (try directory.keepListed(endpointID, name: name, listedBefore: before),
                 try directory.others(than: endpointID))
            }
        }.value
        // Turned off meanwhile: make sure the listing just refreshed is gone.
        guard settings.iCloudKeychain else {
            Task.detached { try? directory.remove(endpointID) }
            return
        }
        switch result {
        case .success((.listed, let devices)):
            if settings.listedID != endpointID { settings.listedID = endpointID }
            listed = devices
            directoryProblem = nil
        case .success((.forgotten, _)):
            settings.iCloudKeychain = false
            settings.listedID = nil
            listed = []
            directoryProblem = nil
            directoryNotice = "Another Mac forgot this one, so it left iCloud Keychain's device list. "
                + "Turn on iCloud Keychain to join again."
            if running { start() }
        case .failure(let error):
            directoryProblem = "\(error)"
        }
    }

    /// Joins or leaves the directory. Leaving removes this Mac's listing from
    /// every device. Takes effect at the next start.
    func setICloudKeychain(_ on: Bool) {
        guard on != settings.iCloudKeychain else { return }
        settings.iCloudKeychain = on
        directoryNotice = nil
        directoryProblem = nil
        if on {
            Task { await syncDirectory() }
        } else {
            settings.listedID = nil
            listed = []
            if let directory, let endpointID { Task.detached { try? directory.remove(endpointID) } }
        }
    }

    /// Removes another device's listing, from every device. Nobody trusts it
    /// until it joins again; if conflux is running there, it notices and
    /// stays out.
    func forget(_ id: String) {
        guard let directory else { return }
        listed.removeAll { $0.endpointID == id }
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    try directory.remove(id)
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            if let failure { directoryProblem = failure }
            node.refreshSoon()
        }
    }

    /// Adds another device's endpoint ID. Returns why not, if it can't.
    func addPeer(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DeviceIdentity.isEndpointID(id) else {
            return "An endpoint ID is 64 characters, 0-9 and a-f. Copy it from the other Mac's conflux window."
        }
        guard id != endpointID else { return "That's this Mac's own ID." }
        if !settings.peers.contains(id) { settings.peers.append(id) }
        return nil
    }

    func removePeer(_ id: String) { settings.peers.removeAll { $0 == id } }

    /// The model file as the node runs it: the starter model when none is
    /// chosen, and chosen files opened through their bookmarks. Nil when
    /// there's none to serve.
    private func modelFileToServe() throws -> ModelConfig? {
        var config: ModelConfig?
        if settings.host?.model.isEmpty ?? true {
            // None chosen: the starter model, if the app has one. It's inside
            // the app, so it needs no bookmark.
            config = starter.map { StarterModel.serving($0, from: settings.host ?? ModelConfig(model: "")) }
        } else if var host = settings.host {
            // In the sandbox, the model files open only through the bookmarks
            // made when they were chosen.
            let paths = try access.open([host.model] + (host.projector.map { [$0] } ?? []))
            host.model = paths[0]
            if host.projector != nil { host.projector = paths[1] }
            // Keep a moved file's new path.
            if host.model != settings.host?.model || host.projector != settings.host?.projector {
                settings.host?.model = host.model
                settings.host?.projector = host.projector
            }
            config = host
        }
        // The app runs models in-process: a sandboxed app can't run
        // llama-server. `conflux serve --runtime llama-server` can.
        config?.runtime = .inProcess
        return config
    }

    func start() {
        problem = nil
        var settings = settings
        if settings.servesModelFile {
            do {
                settings.host = try modelFileToServe()
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        Task {
            do {
                port = try await node.start(settings, directory: directory)
                running = true
                intent = .serving
            } catch {
                problem = "Couldn't start the gateway on port \(settings.port): \(error.localizedDescription)"
            }
        }
    }

    /// Turns the model file on or off. While conflux runs, it starts at once,
    /// or stops taking requests and goes once those it runs have finished,
    /// or, `cancelling`, at once, each going to another host.
    func setServesModelFile(_ on: Bool, cancelling: Bool = false) {
        guard on != settings.servesModelFile else { return }
        settings.servesModelFile = on
        guard running else { return }
        problem = nil
        let config: ModelConfig?
        do {
            config = on ? try modelFileToServe() : nil
        } catch {
            problem = error.localizedDescription
            settings.servesModelFile = false
            return
        }
        let intent = intent
        Task {
            await node.setModelFile(config, cancelling: cancelling)
            await node.setIntent(intent)
        }
    }

    /// Turns Apple's model on or off, at once while conflux runs, as
    /// `setServesModelFile` does.
    func setAppleModel(_ on: Bool, cancelling: Bool = false) {
        guard on != settings.appleModel.enabled else { return }
        settings.appleModel.enabled = on
        guard running else { return }
        let apple = on ? settings.appleModel : nil
        let intent = intent
        Task {
            await node.setAppleModel(apple, cancelling: cancelling)
            await node.setIntent(intent)
        }
    }

    func stop() {
        Task {
            await node.stop()
            access.close()
            running = false
            port = nil
        }
    }

    func setIntent(_ intent: OwnerIntent) {
        self.intent = intent
        Task { await node.setIntent(intent) }
    }

    var token: String? { try? TokenStore.token() }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rotateToken() {
        _ = try? TokenStore.rotate()
        objectWillChange.send()
        if running { start() }
    }

    /// Whether this Mac's model is set to no slots: it runs no requests
    /// itself, and its gateway sends them all to peers.
    var servesNoSlots: Bool { settings.servesModelFile && settings.host?.slots == 0 }

    /// Requests running on this Mac's model now, slots being removed
    /// included.
    var runningHere: Int { host?.active ?? 0 }

    /// Changes how many requests this Mac's model runs at once, and, while
    /// conflux runs, applies it without stopping. Requests running in slots
    /// that go finish first, unless `cancelling`.
    func setSlots(_ slots: Int, cancelling: Bool = false) {
        var host = settings.host ?? ModelConfig(model: "")
        host.slots = slots
        settings.host = host
        guard running else { return }
        let previous = resizing
        resizing = Task { [node] in
            await previous?.value
            await node.setSlots(slots, cancelling: cancelling)
        }
    }

    /// Rests this Mac's models at serious heat, or stops, at once while
    /// conflux runs.
    func setCoolDown(_ on: Bool) {
        settings.coolDown = on
        heatStatus.box = on ? .on : .off
        Task { [node] in await node.setCoolDown(on) }
    }

    /// Goes back to the starter model, keeping the other model settings.
    func useStarter() {
        guard var host = settings.host else { return }
        host.model = ""
        host.projector = nil
        settings.host = host
        access.keep(only: [])
    }

    func choose(projector: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = projector ? "Choose the model's multimodal projector (mmproj)" : "Choose a GGUF model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        do {
            try access.remember(url)
        } catch where ModelAccess.sandboxed {
            // It still opens until the app quits, but not after.
            problem = "conflux can open \(url.lastPathComponent) until it quits, but not after: \(error.localizedDescription)"
        } catch {}
        var host = settings.host ?? ModelConfig(model: "")
        if projector { host.projector = url.path } else { host.model = url.path }
        settings.host = host
        access.keep(only: [host.model] + (host.projector.map { [$0] } ?? []))
    }
}
