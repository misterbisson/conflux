import ConfluxCore
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
/// A bookmark that doesn't resolve, as when its drive isn't connected, is
/// kept and tried again, until the person removes it. One whose drive is
/// there and whose file isn't is said to be missing (InPlaceFile), and is
/// kept the same way.
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

    /// The files used in place that are there now.
    var inPlace: [URL] { kept.compactMap { $0.available ? $0.url : nil } }

    /// A file used in place that conflux can't reach now: on a drive that
    /// isn't connected, or missing, deleted or moved. It's kept, and tried
    /// again.
    struct Unavailable: Identifiable {
        let id: UUID
        let name: String
        /// Its drive is there and it isn't. Otherwise, as far as can be
        /// told, its drive isn't connected.
        let missing: Bool
    }

    var unavailable: [Unavailable] {
        kept.filter { !$0.available }.map { Unavailable(id: $0.id, name: $0.name, missing: $0.missing) }
    }

    private struct Kept {
        let id = UUID()
        /// The file's name when it was chosen, to show while it can't be
        /// reached.
        var name: String
        var bookmark: Data
        /// Where the bookmark resolved, while it does.
        var url: URL?
        var accessing = false
        /// Whether, when it was last tried, its volume was there and it
        /// wasn't (InPlaceFile). Not saved: it's tried again at launch.
        var missing = false

        var available: Bool { url.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false }

        func plist() -> [String: Any] { ["name": name, "bookmark": bookmark] }
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
        for item in UserDefaults.standard.array(forKey: Self.key) ?? [] {
            if let entry = item as? [String: Any], let name = entry["name"] as? String,
               let bookmark = entry["bookmark"] as? Data {
                kept.append(Kept(name: name, bookmark: bookmark))
            } else if let bookmark = item as? Data {
                // Saved before the name was: read it from the bookmark.
                let values = URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: bookmark)
                kept.append(Kept(name: values?.name ?? "A model file", bookmark: bookmark))
                needsSaving = true
            }
        }
        retry()
    }

    @ObservationIgnored private var needsSaving = false

    func isInPlace(_ url: URL) -> Bool { kept.contains { $0.url == url } }

    /// Resolves the bookmarks of files that can't be reached, so a drive
    /// that's connected again shows its files. Called at launch, when the
    /// app comes to the foreground, and before choosing files.
    func retry() {
        for index in kept.indices where !kept[index].available {
            if let url = kept[index].url, kept[index].accessing { url.stopAccessingSecurityScopedResource() }
            kept[index].url = nil
            kept[index].accessing = false
            kept[index].missing = false
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: kept[index].bookmark, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            } catch {
                let facts = InPlaceFile.Facts(failure: error, bookmark: kept[index].bookmark, own: Probe.documents)
                kept[index].missing = InPlaceFile.state(facts) == .missing
                continue
            }
            let accessing = url.startAccessingSecurityScopedResource()
            let state = InPlaceFile.state(InPlaceFile.Facts(
                resolution: FileManager.default.isReadableFile(atPath: url.path)
                    ? .readable(inTrash: Self.inTrash(url)) : .unreadable))
            guard state == .available else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                kept[index].missing = state == .missing
                continue
            }
            kept[index].url = url
            kept[index].accessing = accessing
            if stale, let renewed = try? Self.bookmark(url) {
                kept[index].bookmark = renewed
                needsSaving = true
            }
        }
        // Two bookmarks for one file: the first one stays.
        var paths = Set<String>()
        for item in kept {
            guard let path = item.url?.path else { continue }
            if !paths.insert(path).inserted { forget(item.id) }
        }
        if needsSaving { save() }
    }

    /// Files chosen in the document picker: used in place, or copied in from
    /// iCloud Drive.
    func choose(_ urls: [URL]) async {
        await serially {
            self.problem = nil
            self.retry()
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
        if let item = kept.first(where: { $0.url == url }) {
            forget(item.id)
            save()
        } else if Self.inDocuments(url) {
            do {
                try FileManager.default.removeItem(at: url)
                // A pair's folder goes with its last file.
                if Probe.folder(of: url) != nil {
                    let folder = url.deletingLastPathComponent()
                    if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
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
            bookmark = try Self.bookmark(url)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        // Chosen again: the new bookmark replaces the old.
        for old in kept where old.url?.path == url.path { forget(old.id) }
        kept.append(Kept(name: url.lastPathComponent, bookmark: bookmark, url: url, accessing: accessing))
        save()
    }

    /// Forgets a file that can't be reached now.
    func remove(_ unavailable: Unavailable) {
        problem = nil
        forget(unavailable.id)
        save()
    }

    private func forget(_ id: UUID) {
        guard let index = kept.firstIndex(where: { $0.id == id }) else { return }
        let item = kept.remove(at: index)
        if item.accessing, let url = item.url { url.stopAccessingSecurityScopedResource() }
    }

    private func save() {
        UserDefaults.standard.set(kept.map { $0.plist() }, forKey: Self.key)
        needsSaving = false
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

    /// A bookmark that records the file's volume, so a file whose volume is
    /// there can be told from one whose drive isn't connected.
    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: InPlaceFile.bookmarkKeys, relativeTo: nil)
    }

    // MARK: Where a file is

    /// Whether a file is in the trash, where a bookmark follows a deleted
    /// file (InPlaceFile).
    private static func inTrash(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        guard (try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [],
                                                         toItemAt: url)) != nil else { return false }
        return relationship == .contains
    }

    /// Whether the file is in Documents itself, where it's listed already.
    nonisolated private static func inDocuments(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent().path
            == Probe.documents.resolvingSymlinksInPath().path || Probe.folder(of: url) != nil
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
