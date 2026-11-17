import AppKit
import ConfluxCore

/// Answers apps asking to pair, through `conflux://pair?reply=<URL>`
/// (docs/clients.md). It asks the person about each new app, one at a time,
/// and replies by opening the reply URL in that app only: the app its
/// signature names, which the person was asked about. An app already paired
/// is answered at once, without asking.
@MainActor
final class PairingDesk {
    private let model: AppModel
    private var waiting: [Job] = []
    private var asking: Job?

    struct Job {
        let reply: URL
        let recipient: AppIdentity
        /// The recipient's bundle, where the reply is opened.
        let recipientURL: URL
    }

    init(model: AppModel) {
        self.model = model
    }

    private var events: EventLog? { model.node.events }

    /// Takes a URL another app opened, with the audit token of the process
    /// that sent it, when the Apple Event carried one.
    func open(_ url: URL, sender: Data?) {
        guard let request = Pairing.Request(url) else {
            events?.record("gateway", "refused a URL it doesn't answer: \(url.scheme ?? "")://\(url.host() ?? "")")
            return
        }
        let workspace = NSWorkspace.shared
        let recipientURL = workspace.urlForApplication(toOpen: request.reply)
        let recipient = recipientURL.flatMap(CodeSignature.app(at:))
        let requester = sender.map(CodeSignature.process(auditToken:)) ?? .notAnApp
        let browser = recipientURL.map { app in
            ["https://example.com", "http://example.com"].contains {
                workspace.urlForApplication(toOpen: URL(string: $0)!) == app
            }
        } ?? false
        switch Pairing.decide(recipient: recipient, requester: requester, recipientIsBrowser: browser,
                              paired: model.pairedApps.apps) {
        case .refuse(let reason):
            events?.record("gateway", "refused pairing: \(reason)")
        case .answer(let app):
            guard let recipientURL else { return }
            events?.record("gateway", "answered \(app.name) (\(app.bundleID)), already paired")
            let endpoint = Pairing.endpoint(port: model.port ?? model.settings.port)
            send(Pairing.reply(request.reply, token: app.token, endpoint: endpoint), to: recipientURL,
                 activating: false)
        case .ask(let identity):
            guard let recipientURL else { return }
            // Asked again while waiting: one question is enough.
            let queued = waiting + (asking.map { [$0] } ?? [])
            guard !queued.contains(where: { $0.recipient.isSameApp(as: identity) }) else { return }
            waiting.append(Job(reply: request.reply, recipient: identity, recipientURL: recipientURL))
            next()
        }
    }

    /// Asks about the next app waiting, once the Apple Event that brought it
    /// has been answered.
    private func next() {
        guard asking == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        asking = job
        Task {
            await ask(job)
            asking = nil
            next()
        }
    }

    private func ask(_ job: Job) async {
        let app = job.recipient
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "Let \(app.name) use your models?"
        alert.informativeText = """
            \(app.name) will get a token of its own for conflux's gateway, and can send it requests for any \
            model this Mac and its mesh serve. You can revoke it under Gateway, in Apps.

            \(app.bundleID), \(app.teamID.map { "signed by team \($0)" } ?? "from an unidentified developer, with no Team ID")
            """
        alert.icon = NSWorkspace.shared.icon(forFile: job.recipientURL.path)
        let allow = alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Don't Allow")
        // Return doesn't allow, so a keystroke meant for another app can't.
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else {
            events?.record("gateway", "declined pairing for \(app.name) (\(app.bundleID))")
            send(Pairing.reply(job.reply, error: Pairing.declined), to: job.recipientURL, activating: true)
            return
        }
        do {
            let paired = try model.pairedApps.pair(bundleID: app.bundleID, teamID: app.teamID, name: app.name)
            model.refreshPaired()
            events?.record("gateway", "paired \(app.name) (\(app.bundleID), "
                           + (app.teamID.map { "team \($0)" } ?? "no Team ID") + ")")
            let endpoint = Pairing.endpoint(port: await model.portForPairing())
            send(Pairing.reply(job.reply, token: paired.token, endpoint: endpoint), to: job.recipientURL,
                 activating: true)
        } catch {
            model.problem = "Couldn't pair \(app.name): \(error.localizedDescription)"
        }
    }

    /// Opens a reply in the app it's for, and no other. The URL carries a
    /// token, so it's never logged.
    private func send(_ reply: URL, to app: URL, activating: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        let events = events
        NSWorkspace.shared.open([reply], withApplicationAt: app, configuration: configuration) { _, error in
            if let error { events?.record("gateway", "couldn't reply to \(app.lastPathComponent): \(error.localizedDescription)") }
        }
    }
}
