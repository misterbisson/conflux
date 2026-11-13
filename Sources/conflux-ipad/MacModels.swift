import ConfluxCore
import Foundation
import Observation

/// The models this iPad's Macs serve, and copying one here over the mesh.
///
/// A Mac offers the files of the model it serves, the model and its
/// projector, to the devices it trusts (`HostService`, `/conflux/0/files`).
/// This lists each connected Mac's, and pulls the pair, one file after the
/// other, into Application Support, which survives a relaunch, unlike the
/// temporary folder copies are made in (ModelFiles). Each file is written to
/// a `.partial` file and checked against the Mac's SHA-256 before it's kept.
/// Stopped, by Stop, a lost connection or the app leaving the foreground,
/// the next pull resumes where it stopped. Once both files are checked, they
/// move together into a folder of their own in Documents, named for the
/// model, where the model list finds them. They keep the Mac's file names,
/// which name the model, so the iPad serves it under the same model ID, and,
/// with the same llama.cpp, the same fingerprint.
@MainActor @Observable
final class MacModels {
    /// What a Mac said it offers, or why it couldn't say.
    enum Offer: Equatable {
        case files(PeerFileList)
        case problem(String)
    }

    /// The pull under way or stopped. One at a time.
    struct Pull: Codable, Equatable {
        /// The Mac's endpoint ID.
        var peer: String
        /// The Mac's name when it started, to show.
        var name: String
        var list: PeerFileList
        /// Bytes already in place, of files finished.
        var finished: Int64 = 0
        var progress: PullProgress?
        var state: State = .pulling

        enum State: Codable, Equatable {
            case pulling
            /// Stopped, and can resume: why, if not by Stop.
            case stopped(String?)
            /// Can't resume: get it again.
            case failed(String)
        }

        enum CodingKeys: String, CodingKey { case peer, name, list }

        var folder: String { MacModels.folder(for: list) }
        var received: Int64 { finished + (progress?.received ?? 0) }
        var total: Int64 { list.size }
    }

    private(set) var offers: [String: Offer] = [:]
    private(set) var pull: Pull?
    /// What's left to see after a pull finished or failed.
    private(set) var notice: String?

    @ObservationIgnored private let server: Server
    @ObservationIgnored private var listing: Set<String> = []
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Why the pull is being stopped, when it isn't by Stop.
    @ObservationIgnored private var stopReason: String?
    /// Called once a pair is in Documents, so the model list reads it.
    @ObservationIgnored var arrived: () -> Void = {}

    private static let key = "macPull"
    /// How often a Mac's offer is read again.
    private static let interval: Duration = .seconds(10)

    /// What to expect, for the estimate before a pull: measured between two
    /// processes on one Mac on a direct path, and what n0 lists for its
    /// shared relays (docs/design.md, *iroh, through apple-iroh*).
    static let directRate = 25e6
    static let relayRate = 5e6

    init(server: Server) {
        self.server = server
        // A pull the app ended in the middle of, to resume.
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var saved = try? JSONDecoder().decode(Pull.self, from: data) {
            saved.state = .stopped("conflux closed before it finished")
            pull = saved
        }
    }

    // MARK: Where files go

    /// Where pulls are made: kept across launches, and out of backups.
    static var pulling: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pulling")
    }

    /// A folder name for the pair: the model's ID, which comes from its
    /// file's name, without anything a path could take as a separator.
    nonisolated static func folder(for list: PeerFileList) -> String {
        let name = list.modelID ?? list.model.map { ($0.name as NSString).deletingPathExtension } ?? "model"
        let cleaned = String(name.map { "/:\\".contains($0) ? "-" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "model" : cleaned
    }

    /// Whether this iPad has these files already: the same names and sizes,
    /// the starter model's included.
    func alreadyHere(_ list: PeerFileList, among files: [URL]) -> Bool {
        !list.files.isEmpty && list.files.allSatisfy { file in
            files.contains { $0.lastPathComponent == file.name && Int64(Probe.size($0)) == file.size }
        }
    }

    /// Storage free for files, as iPadOS counts it for something the person
    /// asked for.
    static var freeStorage: Int64? {
        (try? Probe.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Listing

    /// Reads each connected Mac's offer now and every few seconds, while the
    /// mesh is up.
    func startRefreshing() {
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stopRefreshing() {
        refreshing?.cancel()
        refreshing = nil
        offers = [:]
    }

    /// Asks each Mac in the mesh what it offers, one request each at a time.
    /// A Mac still hashing its model answers once it has.
    func refresh() {
        let peers = server.peers.map(\.endpointID)
        for gone in offers.keys where !peers.contains(gone) { offers[gone] = nil }
        let node = server.node
        for peer in peers where !listing.contains(peer) {
            listing.insert(peer)
            Task {
                let offer: Offer
                do {
                    offer = .files(try await node.files(of: peer))
                } catch PeerFilesError.interrupted(let why) {
                    offer = .problem(why)
                } catch let error as PeerFilesError {
                    offer = .problem(error.description)
                } catch {
                    offer = .problem(error.localizedDescription)
                }
                listing.remove(peer)
                if server.peers.contains(where: { $0.endpointID == peer }) { offers[peer] = offer }
            }
        }
    }

    // MARK: Pulling

    var active: Bool { pull?.state == .pulling }

    /// Starts copying a Mac's model and projector here.
    func get(_ list: PeerFileList, from peer: String, name: String) {
        guard !active else { return }
        if let pull, pull.list != list || pull.peer != peer { discard() }
        notice = nil
        pull = Pull(peer: peer, name: name, list: list)
        save()
        run()
    }

    /// Picks up a stopped pull where it stopped.
    func resume() {
        guard var pull, case .stopped = pull.state else { return }
        notice = nil
        pull.state = .pulling
        self.pull = pull
        run()
    }

    /// Stops, keeping what has arrived, to resume.
    func stop() {
        task?.cancel()
    }

    /// Stops for a reason other than Stop, to resume.
    func pause(_ why: String) {
        guard active else { return }
        stopReason = why
        task?.cancel()
    }

    /// Throws away what has arrived of a pull that isn't running.
    func discard() {
        guard !active else { return }
        task = nil
        if let pull { try? FileManager.default.removeItem(at: Self.pulling.appending(path: pull.folder)) }
        pull = nil
        save()
        KeepAwake.set(.pulling, false)
    }

    private func run() {
        guard let pull else { return }
        stopReason = nil
        KeepAwake.set(.pulling, true)
        let node = server.node
        let directory = Self.pulling.appending(path: pull.folder)
        task = Task {
            do {
                try Self.prepare(directory)
                var finished: Int64 = 0
                for file in pull.list.files {
                    let destination = directory.appending(path: file.name)
                    // Checked already, before a stop.
                    if (try? destination.checkResourceIsReachable()) == true, Probe.size(destination) == file.size {
                        finished += file.size
                        continue
                    }
                    self.pull?.finished = finished
                    self.pull?.progress = nil
                    let done = finished
                    try await node.pull(file, from: pull.peer, to: destination,
                                        partial: directory.appending(path: file.name + ".partial")) { progress in
                        Task { @MainActor in
                            guard self.pull?.state == .pulling, self.pull?.finished == done else { return }
                            self.pull?.progress = progress
                        }
                    }
                    finished += file.size
                }
                try Self.moveIn(directory, as: pull.folder)
                self.pull = nil
                notice = "\(pull.list.modelID ?? pull.folder) is on this iPad, from \(pull.name)."
                arrived()
            } catch is CancellationError {
                self.pull?.state = .stopped(stopReason)
            } catch PeerFilesError.interrupted(let why) {
                self.pull?.state = .stopped(Task.isCancelled ? stopReason : why)
            } catch let error as PeerFilesError where error == .changed || error == .corrupt {
                // What has arrived is no use: start again from a new list.
                try? FileManager.default.removeItem(at: directory)
                self.pull?.state = .failed(error == .changed
                    ? "The model on \(pull.name) changed since it was listed. Get it again."
                    : "The copy didn't match the Mac's file, and was thrown away. Get it again.")
            } catch let error as PeerFilesError {
                self.pull?.state = .stopped(error.description)
            } catch {
                self.pull?.state = .stopped(error.localizedDescription)
            }
            save()
            if !active { KeepAwake.set(.pulling, false) }
        }
    }

    /// Makes the folder, out of backups: the files can be pulled again.
    private static func prepare(_ directory: URL) throws {
        var pulling = Self.pulling
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? pulling.setResourceValues(values)
    }

    /// Moves the checked pair into Documents, in a folder of its own,
    /// replacing files of the same names there.
    private static func moveIn(_ directory: URL, as folder: String) throws {
        let manager = FileManager.default
        let target = Probe.documents.appending(path: folder)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "gguf" }
        for file in files {
            let destination = target.appending(path: file.lastPathComponent)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: file, to: destination)
        }
        try? manager.removeItem(at: directory)
    }

    /// Keeps a pull that can resume, for the next launch.
    private func save() {
        var resumable = false
        switch pull?.state {
        case .pulling?, .stopped?: resumable = true
        case .failed?, nil: break
        }
        if resumable, let data = try? JSONEncoder().encode(pull) {
            UserDefaults.standard.set(data, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    // MARK: Words

    /// How long `bytes` take at `rate`, in words.
    static func duration(_ bytes: Int64, at rate: Double) -> String {
        let seconds = max(1, Double(bytes) / max(rate, 1))
        return Duration.seconds(seconds.rounded(.up))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSecond / 1e6)
    }
}
