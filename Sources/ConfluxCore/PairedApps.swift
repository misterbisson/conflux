import Foundation

/// An app on this Mac with a token of its own for the gateway. It's known by
/// its code signature, its bundle ID and Team ID, never by a name it gives:
/// an app with the same bundle ID from another team is another app.
public struct PairedApp: Codable, Sendable, Equatable, Identifiable {
    public var bundleID: String
    /// Nil for a build with no Team ID, signed ad hoc or not at all.
    public var teamID: String?
    /// What the app calls itself, for the window.
    public var name: String
    public var token: String
    public var paired: Date
    /// When it last sent a request, to the minute or so: kept in the file at
    /// most once a minute.
    public var lastUsed: Date?

    public var id: String { Self.id(bundleID: bundleID, teamID: teamID) }

    public static func id(bundleID: String, teamID: String?) -> String {
        "\(teamID ?? "-").\(bundleID)"
    }
}

/// The apps paired with this gateway, kept beside the owner's token in a file
/// only this user can read. The gateway takes any of their tokens as well as
/// the owner's, and reads them at every request, so an app revoked while
/// conflux runs gets `401` at its next one.
public final class PairedApps: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Held across reading the apps and writing them, so writes land in the
    /// order of the changes they carry.
    private let writing = NSLock()
    private var byID: [String: PairedApp] = [:]
    /// Each app's `lastUsed` as the file has it, to write it again only
    /// once it's a minute behind.
    private var saved: [String: Date] = [:]
    static let lastUsedInterval: TimeInterval = 60

    /// `paired-apps.json` beside the owner's token: in the app's container
    /// for the app.
    public static var defaultURL: URL {
        TokenStore.defaultURL.deletingLastPathComponent().appending(path: "paired-apps.json")
    }

    /// Reads the file, if there is one. One that can't be read pairs nothing.
    public init(url: URL = PairedApps.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let apps = try? Self.decoder.decode([PairedApp].self, from: data) {
            for app in apps { byID[app.id] = app }
            saved = byID.compactMapValues(\.lastUsed)
        }
    }

    /// Every paired app, by name.
    public var apps: [PairedApp] {
        lock.withLock { Array(byID.values) }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }

    /// Pairs an app, or, already paired, gives it the token it has, under the
    /// name it gives now.
    @discardableResult
    public func pair(bundleID: String, teamID: String?, name: String, at date: Date = Date()) throws -> PairedApp {
        let id = PairedApp.id(bundleID: bundleID, teamID: teamID)
        let token = try TokenStore.newToken()
        let app = lock.withLock {
            var app = byID[id] ?? PairedApp(bundleID: bundleID, teamID: teamID, name: name, token: token, paired: date)
            app.name = name
            byID[id] = app
            return app
        }
        try save()
        return app
    }

    /// Takes an app's token away. Unknown, it does nothing.
    public func revoke(_ id: String) throws {
        let removed = lock.withLock {
            saved[id] = nil
            return byID.removeValue(forKey: id) != nil
        }
        if removed { try save() }
    }

    /// The app a token belongs to, compared with every app's in constant
    /// time, and notes that it was used.
    public func app(withToken token: String, at date: Date = Date()) -> PairedApp? {
        let (found, due): (PairedApp?, Bool) = lock.withLock {
            var found: PairedApp?
            // Every token compared, the match or not, so the time taken
            // says nothing about which matched.
            for app in byID.values where Gateway.constantTimeEqual(token, app.token) { found = app }
            guard var app = found else { return (nil, false) }
            app.lastUsed = date
            byID[app.id] = app
            if let last = saved[app.id], date.timeIntervalSince(last) < Self.lastUsedInterval {
                return (app, false)
            }
            saved[app.id] = date
            return (app, true)
        }
        // A lost write of when it was used costs nothing that matters.
        if due { try? save() }
        return found
    }

    /// Writes the apps as they are now, whole, to a file only this user can
    /// read, in a folder only this user can open.
    private func save() throws {
        try writing.withLock {
            let apps = lock.withLock { byID.values.sorted { $0.id < $1.id } }
            let data = try Self.encoder.encode(apps)
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
