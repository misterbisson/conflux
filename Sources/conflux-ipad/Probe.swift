import ConfluxCore
import ConfluxUI
import Foundation
import Observation
import UIKit

/// One check of one model: did it load and read its input, and what memory
/// did that take.
struct ProbeResult: Codable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Loaded, passed the self-check, and answered a timed request.
        case passed
        /// Loaded or tried to, and reported what went wrong.
        case failed
        /// The app ended while the model was loading or running, and found
        /// this unfinished at the next launch. On an iPad, almost always the
        /// per-app memory limit.
        case killed
    }

    var id = UUID()
    var date = Date()
    var machine: String
    var system: String
    var model: String
    var modelBytes: UInt64
    var projector: String?
    var projectorBytes: UInt64?
    var slots: Int
    var contextPerSlot: Int
    var outcome: Outcome = .killed
    var detail: String?
    /// What the process could still allocate before loading.
    var availableBefore: UInt64
    var footprintBefore: UInt64
    /// From the start to the self-check passing, hashing the files included
    /// the first time a file is seen.
    var loadSeconds: Double?
    var footprintAfterLoad: UInt64?
    var availableAfterLoad: UInt64?
    /// The highest footprint since the app launched.
    var peakFootprint: UInt64?
    var requestSeconds: Double?
    var completionTokens: Int?
    var thermal: String
    var charging: Bool?
}

/// The iPad app's first version: load a model the person added, check
/// it, and record what memory it took (docs/plan.md, Phase 3, step 1).
@MainActor @Observable
final class Probe {
    /// Models used in place, and the copying in of others.
    let files: ModelFiles
    private(set) var models: [URL] = []
    private(set) var projectors: [URL] = []
    private(set) var results: [ProbeResult] = []
    private(set) var running = false
    private(set) var status: String?
    /// What iPadOS allowed this process at launch: its footprint plus what it
    /// could still allocate.
    let limitAtLaunch: UInt64

    static let killedDetail = "the app ended while the model was loading or running; on an iPad that's "
        + "almost always the per-app memory limit"

    init() {
        limitAtLaunch = Memory.footprint.now + Memory.available
        files = ModelFiles()
        UIDevice.current.isBatteryMonitoringEnabled = true
        results = (try? JSONDecoder().decode([ProbeResult].self, from: Data(contentsOf: Self.resultsURL))) ?? []
        // A check that was still running when the app ended didn't finish.
        if let data = try? Data(contentsOf: Self.pendingURL),
           let unfinished = try? JSONDecoder().decode(ProbeResult.self, from: data) {
            results.append(unfinished)
            save()
        }
        try? FileManager.default.removeItem(at: Self.pendingURL)
        reload()
    }

    // MARK: Files

    /// Where models are copied in: the folder Finder and the Files app show
    /// for conflux. Models used in place are elsewhere (ModelFiles).
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var resultsURL: URL { documents.appending(path: "probe-results.json") }
    static var pendingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "probe-pending.json")
    }

    func reload() {
        // A drive connected again since: its files are back.
        files.retry()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: nil))
            ?? []
        let ggufs = (files.filter { $0.pathExtension.lowercased() == "gguf" } + self.files.inPlace)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // A projector says so in its header. Only a file whose header can't
        // be read goes by its name. Each file is read once for each version
        // of it, however often the list is.
        let added = ggufs.filter { GGUFFile($0).isProjector }
        // The starter model the app ships comes first, so there's something
        // to check before any model is added.
        let starter = StarterModel.files().map { (URL(fileURLWithPath: $0.model), URL(fileURLWithPath: $0.projector)) }
        projectors = (starter.map { [$0.1] } ?? []) + added
        models = (starter.map { [$0.0] } ?? []) + ggufs.filter { !added.contains($0) }
    }

    /// Files chosen in the document picker.
    func choose(_ urls: [URL]) async {
        await files.choose(urls)
        reload()
    }

    /// A file another app opened in conflux.
    func open(_ url: URL) async {
        await files.open(url)
        reload()
    }

    /// Forgets a model used in place, or deletes a copy.
    func remove(_ url: URL) {
        files.remove(url)
        reload()
    }

    /// Forgets a model used in place that can't be reached now.
    func remove(_ unavailable: ModelFiles.Unavailable) {
        files.remove(unavailable)
        reload()
    }

    /// Whether a file is the starter model's, inside the app.
    static func included(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == StarterModel.folder
            && url.path.hasPrefix(Bundle.main.bundlePath)
    }

    /// A file's name and size, for choosing it.
    func label(_ url: URL) -> String {
        let note = Self.included(url) ? " · included" : files.isInPlace(url) ? " · in place" : ""
        return "\(url.lastPathComponent) · \(Memory.gigabytes(Self.size(url)))" + note
    }

    static func size(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(results).write(to: Self.resultsURL, options: .atomic)
    }

    func clear() {
        results = []
        save()
    }

    // MARK: Checking

    var thermal: String { Thermal.label }

    var charging: Bool? {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        case .unplugged: false
        default: nil
        }
    }

    func check(model: URL, projector: URL?, slots: Int, contextPerSlot: Int) async {
        guard !running else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false
            status = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }

        var result = ProbeResult(
            machine: Memory.machine, system: UIDevice.current.systemVersion,
            model: model.lastPathComponent, modelBytes: Self.size(model),
            projector: projector?.lastPathComponent, projectorBytes: projector.map(Self.size),
            slots: slots, contextPerSlot: contextPerSlot, detail: Self.killedDetail,
            availableBefore: Memory.available, footprintBefore: Memory.footprint.now,
            thermal: thermal, charging: charging)
        // Written first, so a run iPadOS ends is still recorded.
        let pendingDirectory = Self.pendingURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(result).write(to: Self.pendingURL, options: .atomic)

        status = "Loading \(model.lastPathComponent) and running the self-check…"
        let config = ModelConfig(runtime: .inProcess, model: model.path, projector: projector?.path, slots: slots,
                                 contextPerSlot: contextPerSlot, selfCheck: true)
        let host = LlamaHost(id: "probe", config: config)
        let started = Date()
        await host.start()
        result.loadSeconds = Date().timeIntervalSince(started)
        result.footprintAfterLoad = Memory.footprint.now
        result.availableAfterLoad = Memory.available

        switch await host.availability {
        case .available:
            status = "Timing one request…"
            do {
                let probe = try SelfCheck.probe(vision: projector != nil)
                let sent = Date()
                let reply = try await host.complete(probe.body, timeout: 300)
                result.requestSeconds = Date().timeIntervalSince(sent)
                result.completionTokens = Self.completionTokens(in: reply.body)
                result.outcome = (200..<300).contains(reply.status) ? .passed : .failed
                result.detail = result.outcome == .passed ? nil
                    : "the timed request answered \(reply.status)"
            } catch {
                result.outcome = .failed
                result.detail = "the timed request failed: \(error)"
            }
        case .failed(let why), .starting(let why), .paused(let why):
            result.outcome = .failed
            result.detail = why
        case .offline:
            result.outcome = .failed
            result.detail = "the host went offline"
        }
        result.peakFootprint = Memory.footprint.peak
        host.stop()

        results.append(result)
        save()
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }

    static func completionTokens(in body: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        return usage["completion_tokens"] as? Int
    }

    // MARK: Sharing

    /// The results as a Markdown table, to paste into
    /// docs/measurements.md. Device kind and memory only: nothing that
    /// identifies this iPad or its owner.
    var summary: String {
        var lines = [
            "conflux memory probe: \(Memory.machine), iPadOS \(UIDevice.current.systemVersion), "
                + "\(Memory.gigabytes(ProcessInfo.processInfo.physicalMemory)) of memory, "
                + "\(Memory.gigabytes(limitAtLaunch)) allowed at launch",
            "",
            "| model | projector | slots × context | outcome | load s | footprint after load | peak | left after load | request s | tokens |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
        func gigabytes(_ value: UInt64?) -> String { value.map(Memory.gigabytes) ?? "–" }
        for r in results {
            let model = "\(r.model) (\(Memory.gigabytes(r.modelBytes)))"
            let projector = r.projector.map { "\($0) (\(Memory.gigabytes(r.projectorBytes ?? 0)))" } ?? "–"
            lines.append("| \(model) | \(projector) | \(r.slots) × \(r.contextPerSlot) | \(r.outcome.rawValue) | "
                + "\(seconds(r.loadSeconds)) | \(gigabytes(r.footprintAfterLoad)) | \(gigabytes(r.peakFootprint)) | "
                + "\(gigabytes(r.availableAfterLoad)) | \(seconds(r.requestSeconds)) | "
                + "\(r.completionTokens.map(String.init) ?? "–") |")
        }
        let notes = results.compactMap { r in r.detail.map { "- \(r.model): \($0)" } }
        if !notes.isEmpty { lines += [""] + notes }
        return lines.joined(separator: "\n")
    }
}
