import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers

extension UTType {
    /// llama.cpp's model file. conflux doesn't own the format, so the app
    /// imports the type rather than exporting it (project.yml).
    static let gguf = UTType(importedAs: "ai.ggml.gguf")
}

/// The model files the iPad lists besides those in its Documents folder, and
/// how files get there.
///
/// A file chosen in the document picker, on this iPad or on an external
/// drive, is used where it is, through a security-scoped bookmark that's kept
/// and reopened at launch, as the Mac keeps the files chosen in its open
/// panel (Sources/conflux/ModelAccess.swift). Access is held for as long as
/// the file is listed: llama.cpp maps the file, and reads it while serving.
///
/// A file in iCloud Drive is copied into Documents instead, because iCloud can
/// evict a file's local copy, which isn't safe under a loaded model. So is a
/// file opened in conflux from another app, such as Safari's downloads.
@MainActor @Observable
final class ModelFiles {
    struct Copy: Equatable {
        var name: String
        var fromICloud: Bool
        /// How much is copied. Nil while iCloud downloads the file first.
        var fraction: Double?
    }

    private(set) var copying: Copy?
    var problem: String?

    /// The files used in place that are there now. A drive that's been
    /// disconnected hides its files until it's back.
    var inPlace: [URL] { kept.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) } }

    private struct Kept {
        var url: URL
        var bookmark: Data
        var accessing: Bool
    }

    private var kept: [Kept] = []
    private var job: CopyJob?
    /// The last of the copies and choices, which run one at a time.
    private var queue: Task<Void, Never>?
    private static let key = "modelBookmarks"
    /// Copies are made here, then moved into Documents once they're whole.
    private static var staging: URL { FileManager.default.temporaryDirectory.appending(path: "copying") }

    init() {
        // A copy the app ended in the middle of.
        try? FileManager.default.removeItem(at: Self.staging)
        let saved = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        for data in saved {
            var stale = false
            // One that can't be resolved, or renewed, is dropped: the file is
            // gone, or conflux can't reach it.
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            let bookmark = stale ? try? url.bookmarkData() : data
            guard let bookmark, FileManager.default.isReadableFile(atPath: url.path),
                  !kept.contains(where: { $0.url.path == url.path }) else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                continue
            }
            kept.append(Kept(url: url, bookmark: bookmark, accessing: accessing))
        }
        if kept.map(\.bookmark) != saved { save() }
    }

    func isInPlace(_ url: URL) -> Bool { kept.contains { $0.url == url } }

    /// Files chosen in the document picker: used in place, or copied in from
    /// iCloud Drive.
    func choose(_ urls: [URL]) async {
        await serially {
            self.problem = nil
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if Self.inDocuments(url) { continue }
                do {
                    if Self.inICloud(url) {
                        try await self.copy(url, fromICloud: true)
                    } else {
                        try self.keep(url)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.problem = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    /// A file opened in conflux from another app, which is copied in.
    func open(_ url: URL) async {
        await serially {
            self.problem = nil
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if Self.inDocuments(url) { return }
            do {
                if Self.inInbox(url) {
                    // iPadOS copied it in already, to Documents/Inbox.
                    try self.moveIn(url)
                } else {
                    try await self.copy(url, fromICloud: Self.inICloud(url))
                }
            } catch is CancellationError {
            } catch {
                self.problem = "Couldn't copy \(url.lastPathComponent) into conflux: \(error.localizedDescription)"
            }
        }
    }

    /// Stops the copy being made, and leaves nothing of it.
    func cancel() { job?.cancel() }

    /// Forgets a file used in place, which stays where it is, or deletes a
    /// copy.
    func remove(_ url: URL) {
        problem = nil
        if let index = kept.firstIndex(where: { $0.url == url }) {
            let item = kept.remove(at: index)
            if item.accessing { item.url.stopAccessingSecurityScopedResource() }
            save()
        } else if Self.inDocuments(url) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                problem = "Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Using in place

    private func keep(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData()
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        // Chosen again: the new bookmark replaces the old.
        if let index = kept.firstIndex(where: { $0.url.path == url.path }) {
            let old = kept.remove(at: index)
            if old.accessing { old.url.stopAccessingSecurityScopedResource() }
        }
        kept.append(Kept(url: url, bookmark: bookmark, accessing: accessing))
        save()
    }

    private func save() {
        UserDefaults.standard.set(kept.map(\.bookmark), forKey: Self.key)
    }

    // MARK: Copying in

    private func serially(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        await task.value
    }

    private func copy(_ source: URL, fromICloud: Bool) async throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        // The same file is there already.
        guard let destination = Self.destination(for: source.lastPathComponent, size: size) else { return }
        try FileManager.default.createDirectory(at: Self.staging, withIntermediateDirectories: true)
        let partial = Self.staging.appending(path: UUID().uuidString)
        let job = CopyJob()
        self.job = job
        copying = Copy(name: source.lastPathComponent, fromICloud: fromICloud, fraction: fromICloud ? nil : 0)
        defer {
            copying = nil
            self.job = nil
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Off the cooperative pool: the coordinator blocks while iCloud
                // downloads, and a copy of gigabytes takes a while.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.copyCoordinated(from: source, to: partial, job: job) { fraction in
                            Task { @MainActor in
                                if self.job === job { self.copying?.fraction = fraction }
                            }
                        }
                    })
                }
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func moveIn(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let destination = Self.destination(for: url.lastPathComponent, size: size) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// Where a copy goes in Documents, or nil when a file of the same name
    /// and size is there already. Another of the same name gets a number.
    private static func destination(for name: String, size: Int?) -> URL? {
        let documents = Probe.documents
        var url = documents.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        if let size, Probe.size(url) == UInt64(size) { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        repeat {
            url = documents.appending(path: "\(stem) \(number).\(ext)")
            number += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    /// Reads the file through a file coordinator, which has iCloud download
    /// it first, and copies it.
    nonisolated private static func copyCoordinated(from source: URL, to destination: URL, job: CopyJob,
                                                     progress: (Double) -> Void) throws {
        var coordinated: NSError?
        var copied: (any Error)?
        job.coordinator.coordinate(readingItemAt: source, options: [], error: &coordinated) { readable in
            do {
                try copyBytes(from: readable, to: destination, job: job, progress: progress)
            } catch {
                copied = error
            }
        }
        if job.cancelled { throw CancellationError() }
        if let error = coordinated ?? copied { throw error }
    }

    nonisolated private static func copyBytes(from source: URL, to destination: URL, job: CopyJob,
                                               progress: (Double) -> Void) throws {
        progress(0)
        // On the same volume, a clone: done at once, and it takes no more
        // space until one of the two changes.
        let cloned = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return clonefile(from, to, 0) == 0
            }
        }
        if cloned {
            progress(1)
            return
        }
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var done = 0
        var reported = 0
        while true {
            if job.cancelled { throw CancellationError() }
            let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            done += chunk.count
            // A step of a percent at most, so the screen isn't redrawn for
            // every chunk.
            if total > 0, done * 100 / total != reported {
                reported = done * 100 / total
                progress(min(1, Double(done) / Double(total)))
            }
        }
    }

    // MARK: Where a file is

    /// Whether the file is in Documents itself, where it's listed already.
    private static func inDocuments(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent().path
            == Probe.documents.resolvingSymlinksInPath().path
    }

    /// Where iPadOS puts a file another app hands over as a copy.
    private static func inInbox(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent().path
            == Probe.documents.appending(path: "Inbox").resolvingSymlinksInPath().path
    }

    private static func inICloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}

/// One copy, which the person can cancel from the main thread while it runs
/// on another.
private final class CopyJob: @unchecked Sendable {
    /// Its `cancel()` may be called from any thread, and ends a wait for
    /// iCloud to download the file.
    let coordinator = NSFileCoordinator()
    private let flag = Mutex(false)

    var cancelled: Bool { flag.withLock { $0 } }

    func cancel() {
        flag.withLock { $0 = true }
        coordinator.cancel()
    }
}
