import Foundation

/// Keeps the app's access to the model files the user picked.
///
/// In the App Sandbox the app can read a file chosen in an open panel only
/// until it quits. A security-scoped bookmark, made when the file is chosen
/// and kept with the settings, gets that access back at the next launch. Run
/// from source (`swift run`) there's no sandbox, and a path without a bookmark
/// is opened as it is.
@MainActor
final class ModelAccess {
    private static let key = "bookmarks"
    /// Bookmarks by the path they were made for.
    private var bookmarks: [String: Data]
    /// Files being read now, released by `close()`.
    private var accessing: [URL] = []

    static var sandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
    }

    /// Records a file the user chose. Call it while the open panel's access
    /// lasts, which is until the app quits.
    func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        bookmarks[url.path] = data
        save()
    }

    /// Forgets bookmarks for files that are no longer in the settings.
    func keep(only paths: [String]) {
        let before = bookmarks.count
        bookmarks = bookmarks.filter { paths.contains($0.key) }
        if bookmarks.count != before { save() }
    }

    /// Opens the files for as long as the host serves, and returns the paths
    /// to load. A path changes when its file was moved or renamed since it was
    /// chosen; the bookmark follows the file.
    func open(_ paths: [String]) throws -> [String] {
        close()
        return try paths.map { path in
            var stale = false
            guard let data = bookmarks[path],
                  let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else {
                if Self.sandboxed { throw ModelAccessError.choose(again: path) }
                return path
            }
            if url.startAccessingSecurityScopedResource() { accessing.append(url) }
            if stale || url.path != path {
                bookmarks[path] = nil
                remember(url)
            }
            return url.path
        }
    }

    /// Gives up access to the files `open` opened.
    func close() {
        for url in accessing { url.stopAccessingSecurityScopedResource() }
        accessing = []
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }
}

enum ModelAccessError: LocalizedError {
    case choose(again: String)

    var errorDescription: String? {
        switch self {
        case .choose(again: let path):
            "conflux can't open \(URL(fileURLWithPath: path).lastPathComponent) any more. Choose it again."
        }
    }
}
