import ConfluxCore
import ConfluxUI
import Foundation
import Observation
import UIKit

/// The iPad as a host: it serves its model to the Macs' gateways over iroh,
/// and runs no gateway of its own (docs/plan.md, Phase 3).
///
/// It serves only in the foreground, with the screen kept awake, and by
/// default only while charging. In the background iPadOS suspends it, so it
/// drains first, and gateways send their work elsewhere.
@MainActor @Observable
final class Server {
    let node = ConfluxNode()
    /// iCloud Keychain's device directory: the Macs it trusts, and where it
    /// lists itself so they trust it. Nil in a build that isn't signed for
    /// the team, where Macs are added by hand.
    let directory: KeychainDeviceDirectory?
    /// This iPad's endpoint ID, which a Mac adds by hand when there's no
    /// directory.
    let endpointID: String?

    private(set) var running = false
    /// Whether the mesh runs with no host, so this iPad can reach its Macs
    /// to get a model from one (MacModels): while it's in the foreground and
    /// not serving. Its Macs see it serving no model.
    private(set) var meshOnly = false
    /// Whether the mesh is up: serving, or only to reach the Macs.
    var meshUp: Bool { running || meshOnly }
    private(set) var snapshot: SchedulerSnapshot?
    private(set) var peers: [PeerStatus] = []
    private(set) var problem: String?
    private(set) var meshProblem: String?
    private(set) var directoryProblem: String?
    private(set) var directoryNotice: String?
    private(set) var listed: [ListedDevice] = []
    /// Why it isn't taking work while running, if it isn't.
    private(set) var held: String?
    /// This iPad's host's last day by the minute, for the activity chart.
    private(set) var activity: [ActivityMinute] = []
    /// What this process can still allocate before iPadOS ends it, the
    /// least in each reading. Taken while it serves.
    private(set) var memoryLeft = TimeSeries(keeping: .lowest)
    /// The thermal state as a level, the highest in each reading.
    private(set) var heat = TimeSeries(keeping: .highest)
    /// 0 charging, 1 on battery: the worse in each reading.
    private(set) var power = TimeSeries(keeping: .highest)

    var settings: Settings {
        didSet { save() }
    }

    struct Settings: Codable, Equatable {
        /// Macs added by hand.
        var peers: [String] = []
        var iCloudKeychain = true
        /// The ID this iPad last listed in the directory: gone while this is
        /// set means a Mac forgot it.
        var listedID: String?
        var servesOnBattery = false
    }

    private var foreground = true
    private var polling: Task<Void, Never>?
    /// The last start or stop of the node: each waits for the one before,
    /// so serving and the mesh alone never start over each other.
    private var changing: Task<Void, Never>?
    private static let key = "server"
    private static let directoryInterval: Duration = .seconds(10)

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        // The key first: made and kept the first time, it's what the
        // directory finds the team's prefix by, when the Info.plist lacks it.
        endpointID = try? DeviceIdentity.load().endpointID
        directory = KeychainDeviceDirectory.forThisApp()
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIntent() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var host: HostSnapshot? { snapshot?.hosts.first { $0.id == ConfluxNode.localHostID } }

    /// Every Mac this iPad trusts: added by hand, listed in iCloud Keychain,
    /// or both.
    var trusted: [TrustedPeer] {
        TrustedPeer.merge(manual: settings.peers, listed: settings.iCloudKeychain ? listed : [], this: endpointID)
    }

    /// The name this iPad lists itself under. iPadOS gives apps "iPad", so
    /// the kind of iPad goes with it.
    private var deviceName: String { "\(UIDevice.current.name) (\(Memory.machine))" }

    var charging: Bool {
        [.charging, .full].contains(UIDevice.current.batteryState)
    }

    // MARK: Serving

    func start(model: URL, projector: URL?, slots: Int, contextPerSlot: Int) {
        problem = nil
        let config = ModelConfig(runtime: .inProcess, model: model.path, projector: projector?.path, slots: slots,
                                 contextPerSlot: contextPerSlot, selfCheck: true)
        let node = NodeSettings(host: config, requireToken: false, peers: settings.peers,
                                iCloudKeychain: settings.iCloudKeychain, gateway: false)
        let directory = settings.iCloudKeychain ? directory : nil
        guard directory != nil || !settings.peers.isEmpty else {
            problem = "No Mac to serve. Turn on iCloud Keychain, or add a Mac's ID below."
            return
        }
        meshOnly = false
        running = true
        KeepAwake.set(.serving, true)
        // Starting the node stops the mesh it ran alone.
        change {
            await self.syncDirectory()
            guard self.running else { return }
            do {
                try await self.node.start(node, directory: directory)
                self.applyIntent()
            } catch {
                self.problem = "Couldn't start: \(error.localizedDescription)"
                self.stop()
            }
        }
        poll()
    }

    func stop() {
        polling?.cancel()
        polling = nil
        running = false
        held = nil
        KeepAwake.set(.serving, false)
        change {
            await self.node.stop()
            self.snapshot = nil
            self.peers = []
        }
        startMesh()
    }

    /// Runs `work` once the node's last start or stop is done.
    private func change(_ work: @escaping @MainActor () async -> Void) {
        let previous = changing
        changing = Task {
            await previous?.value
            await work()
        }
    }

    /// Reads how the node is doing every second, and the directory every
    /// few, while the mesh is up.
    private func poll() {
        polling?.cancel()
        polling = Task { [weak self] in
            var lastSync = ContinuousClock.now
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.peers = self.node.peers
                self.meshProblem = self.node.meshProblem
                if self.running {
                    self.snapshot = await self.node.scheduler.snapshot()
                    self.memoryLeft.append(Double(Memory.available))
                    self.heat.append(Double(Thermal.level))
                    self.power.append(self.charging ? 0 : 1)
                    if tick % 5 == 0 {
                        self.activity = await self.node.scheduler.activity(
                            since: Date().addingTimeInterval(-86400))[ConfluxNode.localHostID] ?? []
                    }
                    tick += 1
                }
                if ContinuousClock.now - lastSync >= Self.directoryInterval {
                    lastSync = .now
                    await self.syncDirectory()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: The mesh alone

    /// Runs the mesh with no host, while this iPad is in the foreground and
    /// not serving, so it can reach its Macs to get a model from one. It
    /// runs no gateway either, and its Macs see it serving no model.
    func startMesh() {
        guard foreground, !running, !meshOnly else { return }
        let directory = settings.iCloudKeychain ? directory : nil
        guard directory != nil || !settings.peers.isEmpty else { return }
        meshOnly = true
        let node = NodeSettings(host: nil, requireToken: false, peers: settings.peers,
                                iCloudKeychain: settings.iCloudKeychain, gateway: false)
        change {
            await self.syncDirectory()
            guard self.meshOnly else { return }
            do {
                try await self.node.start(node, directory: directory)
            } catch {
                self.meshProblem = "\(error)"
            }
        }
        poll()
    }

    func stopMesh() {
        guard meshOnly else { return }
        meshOnly = false
        polling?.cancel()
        polling = nil
        change {
            await self.node.stop()
            self.peers = []
        }
    }

    /// Starts the mesh alone again, after its Macs changed, or for the
    /// first Mac. Serving takes them at its next start.
    private func macsChanged() {
        if meshOnly { stopMesh() }
        startMesh()
    }

    /// Called as the app comes and goes from the foreground.
    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        applyIntent()
    }

    /// Serving, draining or paused, from the foreground and the power.
    private func applyIntent() {
        guard running else { return }
        let intent: OwnerIntent
        if !foreground {
            // iPadOS suspends it soon: finish what's running, take nothing
            // new, and gateways send work elsewhere.
            intent = .draining
            held = "conflux is in the background"
        } else if !charging && !settings.servesOnBattery {
            intent = .paused
            held = "on battery: plug in this iPad, or turn on Serve on battery"
        } else {
            intent = .serving
            held = nil
        }
        Task { await node.setIntent(intent) }
    }

    func setServesOnBattery(_ on: Bool) {
        settings.servesOnBattery = on
        applyIntent()
    }

    // MARK: The directory

    /// Keeps this iPad listed, and reads the Macs listed. An iPad whose
    /// listing a Mac removed stays out until its owner turns iCloud Keychain
    /// on again.
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
            directoryNotice = "A Mac forgot this iPad, so it left iCloud Keychain's device list. "
                + "Turn on iCloud Keychain to join again."
        case .failure(let error):
            directoryProblem = "\(error)"
        }
    }

    /// Joins or leaves the directory. Leaving removes this iPad's listing
    /// from every device. Serving takes it at its next start.
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
        macsChanged()
    }

    /// Adds a Mac's endpoint ID. Returns why not, if it can't. Serving takes
    /// it at its next start.
    func addPeer(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DeviceIdentity.isEndpointID(id) else {
            return "An endpoint ID is 64 characters, 0-9 and a-f. Copy it from the Mac's conflux window."
        }
        guard id != endpointID else { return "That's this iPad's own ID." }
        if !settings.peers.contains(id) {
            settings.peers.append(id)
            macsChanged()
        }
        return nil
    }

    func removePeer(_ id: String) {
        settings.peers.removeAll { $0 == id }
        macsChanged()
    }
}

/// Keeps the screen awake while anything needs it: serving, checking a
/// model, or getting one from a Mac. iPadOS suspends conflux once the screen
/// locks, which would stop each of them.
@MainActor
enum KeepAwake {
    enum Reason { case serving, checking, pulling }

    private static var reasons: Set<Reason> = []

    static func set(_ reason: Reason, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
