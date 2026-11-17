import Foundation

/// An app, as its code signature says: the identifier it's signed with,
/// which for an app is its bundle ID, and its Team ID, with the name it shows.
public struct AppIdentity: Equatable, Sendable {
    public var bundleID: String
    /// Nil for a build with no Team ID: signed ad hoc, unsigned, or Apple's
    /// own.
    public var teamID: String?
    public var name: String

    public init(bundleID: String, teamID: String?, name: String) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
    }

    /// The same as a paired app's ID, so one can be found by the other.
    public var id: String { PairedApp.id(bundleID: bundleID, teamID: teamID) }

    /// The same app: the same signature. The name doesn't count.
    public func isSameApp(as other: AppIdentity) -> Bool { id == other.id }
}

/// Pairing: an app on this Mac asks for a token of its own by opening
/// `conflux://pair?reply=<its own URL>`. conflux asks the person, and
/// answers by opening the reply URL, in that app only, with the token and
/// the gateway's address, or with an error. docs/clients.md has the contract.
public enum Pairing {
    /// What a reply URL carries.
    public enum ReplyItem {
        public static let token = "token"
        public static let endpoint = "endpoint"
        public static let error = "error"
    }

    /// The `error` a reply carries when the person said no.
    public static let declined = "declined"

    /// A request to pair, read from the URL an app opened.
    public struct Request: Equatable, Sendable {
        /// Where the answer goes: a URL the asking app handles.
        public let reply: URL

        /// Nil unless the URL is `conflux://pair` with a `reply` conflux may
        /// answer.
        public init?(_ url: URL) {
            guard url.scheme?.lowercased() == "conflux", url.host()?.lowercased() == "pair",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let value = items.last(where: { $0.name == "reply" })?.value,
                  let reply = URL(string: value), Pairing.mayReply(to: reply)
            else { return nil }
            self.reply = reply
        }
    }

    /// Schemes a reply never goes to, whichever app handles them: the web's,
    /// which a browser would carry off the Mac with the token in them;
    /// files; mail; and conflux's own.
    static let refusedSchemes: Set<String> = [
        "http", "https", "ws", "wss", "ftp", "file", "data", "javascript", "about", "blob", "mailto", "sms", "tel",
        "conflux",
    ]

    /// Whether a reply may go to this URL: an app's own scheme.
    public static func mayReply(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !refusedSchemes.contains(scheme)
    }

    /// Who opened the pairing URL, as the running process's signature says.
    public enum Requester: Equatable, Sendable {
        /// An app, signed validly.
        case app(AppIdentity)
        /// A command line tool or a system process, not an app, or no
        /// sender at all: then only the recipient counts.
        case notAnApp
        /// An app whose signature isn't valid, or can't be checked, or a
        /// sender that can't be told.
        case invalid
    }

    /// What to do with a request.
    public enum Decision: Equatable, Sendable {
        /// Ask the person whether this app may use the models.
        case ask(AppIdentity)
        /// Already paired: answer at once, without asking.
        case answer(PairedApp)
        /// Don't answer at all, for the reason given, which goes in the log.
        case refuse(String)
    }

    /// Decides what to do with a request.
    ///
    /// - `recipient`: the app the reply URL opens in, from its signature on
    ///   disk, or nil when no app handles it or its signature isn't valid.
    ///   The token goes to this app only, so it's the one the person is
    ///   asked about.
    /// - `requester`: who opened the pairing URL. An app has to be the
    ///   recipient. A command line tool or a system process isn't an app,
    ///   and then only the recipient counts.
    /// - `recipientIsBrowser`: the recipient also opens web pages, so a reply
    ///   to it could leave the Mac.
    public static func decide(recipient: AppIdentity?, requester: Requester, recipientIsBrowser: Bool,
                              paired: [PairedApp]) -> Decision {
        guard let recipient else { return .refuse("no app with a valid signature opens the reply URL") }
        switch requester {
        case .app(let requester) where !requester.isSameApp(as: recipient):
            return .refuse("\(requester.name) (\(requester.bundleID)) asked for a reply to "
                           + "\(recipient.name) (\(recipient.bundleID))")
        case .invalid:
            return .refuse("the app asking has no valid signature")
        default:
            break
        }
        if recipientIsBrowser { return .refuse("\(recipient.name) (\(recipient.bundleID)) opens web pages") }
        if let app = paired.first(where: { $0.id == recipient.id }) { return .answer(app) }
        return .ask(recipient)
    }

    /// The reply for an app that may use the models: its token, and where
    /// the gateway is.
    public static func reply(_ base: URL, token: String, endpoint: URL) -> URL {
        reply(base, [URLQueryItem(name: ReplyItem.token, value: token),
                     URLQueryItem(name: ReplyItem.endpoint, value: endpoint.absoluteString)])
    }

    /// The reply for an app that may not.
    public static func reply(_ base: URL, error: String) -> URL {
        reply(base, [URLQueryItem(name: ReplyItem.error, value: error)])
    }

    /// The gateway's address, as the reply gives it.
    public static func endpoint(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    /// The base URL with these items in its query, in place of any of the
    /// same names it had, and its other items kept.
    static func reply(_ base: URL, _ items: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let ours: Set = [ReplyItem.token, ReplyItem.endpoint, ReplyItem.error]
        components.queryItems = (components.queryItems ?? []).filter { !ours.contains($0.name) } + items
        // A token has no `+`, but `+` in a query reads as a space to some
        // parsers, so it's escaped wherever it appears.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        return components.url ?? base
    }
}
