import AppKit
import ConfluxCore
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
    }

    var body: some Scene {
        WindowGroup("conflux") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NodeSettings {
        didSet { save() }
    }
    @Published private(set) var snapshot: SchedulerSnapshot?
    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var intent: OwnerIntent = .serving
    @Published var problem: String?
    @Published private(set) var peers: [PeerStatus] = []
    @Published private(set) var meshProblem: String?
    @Published private(set) var refused = 0
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
            while !Task.isCancelled {
                if let self {
                    self.snapshot = await self.node.scheduler.snapshot()
                    self.peers = self.node.peers
                    self.meshProblem = self.node.meshProblem
                    self.refused = self.node.refusedConnections
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
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// This Mac's own host, for its model file.
    var host: HostSnapshot? { snapshot?.hosts.first { $0.id == ConfluxNode.localHostID } }

    /// This Mac's host for Apple's on-device model.
    var appleHost: HostSnapshot? { snapshot?.hosts.first { $0.id == ConfluxNode.appleHostID } }

    func peerHost(_ peer: PeerStatus) -> HostSnapshot? { snapshot?.hosts.first { $0.id == peer.hostID } }

    /// The name a peer's host goes by: the trusted peer's name, when it has
    /// one. Nil for this Mac's hosts, and for peers without a name.
    func peerName(of host: HostSnapshot) -> String? {
        guard let endpointID = peers.first(where: { $0.hostID == host.id })?.endpointID else { return nil }
        return trusted.first { $0.endpointID == endpointID }?.name
    }

    /// The model the app ships, served until the person chooses one. Built
    /// from source, there's none.
    let starter = StarterModel.files()

    /// Whether this Mac serves the starter model: none is chosen, and the app
    /// has one.
    var servesStarter: Bool { starter != nil && (settings.host?.model.isEmpty ?? true) }

    var canStart: Bool {
        !(settings.host?.model.isEmpty ?? true) || starter != nil || settings.appleModel.enabled || !trusted.isEmpty
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

    func start() {
        problem = nil
        var settings = settings
        if settings.host?.model.isEmpty ?? true {
            // None chosen: the starter model, if the app has one. It's inside
            // the app, so it needs no bookmark.
            settings.host = starter.map { StarterModel.serving($0, from: settings.host ?? ModelConfig(model: "")) }
        } else if var host = settings.host {
            // In the sandbox, the model files open only through the bookmarks
            // made when they were chosen.
            do {
                let paths = try access.open([host.model] + (host.projector.map { [$0] } ?? []))
                host.model = paths[0]
                if host.projector != nil { host.projector = paths[1] }
            } catch {
                problem = error.localizedDescription
                return
            }
            // Keep a moved file's new path.
            if host.model != settings.host?.model || host.projector != settings.host?.projector {
                self.settings.host?.model = host.model
                self.settings.host?.projector = host.projector
            }
            settings.host = host
        }
        // The app runs models in-process: a sandboxed app can't run
        // llama-server. `conflux serve --runtime llama-server` can.
        settings.host?.runtime = .inProcess
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
