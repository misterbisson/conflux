import Foundation
import Testing
@testable import ConfluxCore

@Suite struct PairingTests {
    let client = AppIdentity(bundleID: "com.example.client", teamID: "TEAM000001", name: "Client")

    func paired(_ app: AppIdentity, token: String = "cfx_client") -> PairedApp {
        PairedApp(bundleID: app.bundleID, teamID: app.teamID, name: app.name, token: token, paired: Date())
    }

    func request(_ text: String) -> Pairing.Request? { Pairing.Request(URL(string: text)!) }

    @Test func readsARequest() {
        #expect(request("conflux://pair?reply=client://conflux")?.reply == URL(string: "client://conflux"))
        #expect(request("CONFLUX://Pair?reply=client%3A%2F%2Fconflux%3Fa%3D1")?.reply
                == URL(string: "client://conflux?a=1"))
    }

    @Test func refusesARequestItCantAnswer() {
        #expect(request("conflux://pair") == nil)
        #expect(request("conflux://other?reply=client://conflux") == nil)
        #expect(request("client://pair?reply=client://conflux") == nil)
        #expect(request("conflux://pair?reply=") == nil)
        #expect(request("conflux://pair?reply=noscheme") == nil)
    }

    @Test(arguments: ["https://example.com/steal", "http://127.0.0.1:9/", "file:///tmp/x", "mailto:a@example.com",
                      "conflux://pair", "javascript:alert(1)", "data:text/plain,x"])
    func neverRepliesToTheWebOrFilesOrItself(_ reply: String) {
        let encoded = reply.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(request("conflux://pair?reply=\(encoded)") == nil)
    }

    @Test func asksAboutAnAppNotYetPaired() {
        let decision = Pairing.decide(recipient: client, requester: .app(client), recipientIsBrowser: false,
                                      paired: [])
        #expect(decision == .ask(client))
    }

    @Test func answersAPairedAppWithoutAsking() {
        let app = paired(client)
        let decision = Pairing.decide(recipient: client, requester: .app(client), recipientIsBrowser: false,
                                      paired: [app])
        #expect(decision == .answer(app))
    }

    @Test func anotherTeamWithTheSameBundleIDIsAskedAbout() {
        let impostor = AppIdentity(bundleID: client.bundleID, teamID: "TEAM000002", name: client.name)
        let decision = Pairing.decide(recipient: impostor, requester: .app(impostor), recipientIsBrowser: false,
                                      paired: [paired(client)])
        #expect(decision == .ask(impostor))
    }

    @Test func refusesWhenTheAskingAppIsntTheOneTheReplyGoesTo() {
        let other = AppIdentity(bundleID: "com.example.other", teamID: "TEAM000002", name: "Client")
        guard case .refuse = Pairing.decide(recipient: client, requester: .app(other), recipientIsBrowser: false,
                                            paired: [paired(client)])
        else { Issue.record("not refused"); return }
    }

    @Test func refusesWithoutAValidSignature() {
        guard case .refuse = Pairing.decide(recipient: nil, requester: .notAnApp, recipientIsBrowser: false,
                                            paired: [])
        else { Issue.record("not refused with no recipient"); return }
        guard case .refuse = Pairing.decide(recipient: client, requester: .invalid, recipientIsBrowser: false,
                                            paired: [])
        else { Issue.record("not refused with an invalid requester"); return }
    }

    @Test func refusesABrowser() {
        guard case .refuse = Pairing.decide(recipient: client, requester: .notAnApp, recipientIsBrowser: true,
                                            paired: [paired(client)])
        else { Issue.record("not refused"); return }
    }

    @Test func aRequestNotFromAnAppIsDecidedByTheRecipient() {
        #expect(Pairing.decide(recipient: client, requester: .notAnApp, recipientIsBrowser: false, paired: [])
                == .ask(client))
    }

    @Test func repliesWithTheTokenAndEndpoint() throws {
        let url = Pairing.reply(URL(string: "client://conflux?state=7&token=old")!, token: "cfx_a-b_c",
                                endpoint: Pairing.endpoint(port: 8090))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.scheme == "client")
        #expect(items.first { $0.name == "state" }?.value == "7")
        #expect(items.filter { $0.name == "token" }.map(\.value) == ["cfx_a-b_c"])
        #expect(items.first { $0.name == "endpoint" }?.value == "http://127.0.0.1:8090/v1")
        #expect(items.first { $0.name == "error" } == nil)
    }

    @Test func repliesWithAnError() throws {
        let url = Pairing.reply(URL(string: "client://conflux")!, error: Pairing.declined)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["error"])
        #expect(items.first?.value == "declined")
    }
}

#if os(macOS)
@Suite struct CodeSignatureTests {
    @Test func readsAnAppOnDisk() throws {
        let app = try #require(CodeSignature.app(at: URL(filePath: "/System/Applications/Calculator.app")))
        #expect(app.bundleID == "com.apple.calculator")
        #expect(app.teamID == nil)
        #expect(!app.name.isEmpty)
    }

    @Test func refusesWhatIsntSigned() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CodeSignatureTests-\(UUID().uuidString)")
        let bundle = folder.appending(path: "Fake.app")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/MacOS"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("#!/bin/sh\n".utf8).write(to: bundle.appending(path: "Contents/MacOS/Fake"))
        #expect(CodeSignature.app(at: bundle) == nil)
        #expect(CodeSignature.app(at: folder.appending(path: "Missing.app")) == nil)
    }

    @Test func aTestRunnerIsNotAnApp() throws {
        let token = try #require(CodeSignature.ownAuditToken())
        #expect(CodeSignature.process(auditToken: token) == .notAnApp)
        #expect(CodeSignature.process(auditToken: Data([1, 2, 3])) == .notAnApp)
    }

    @Test func aProcessThatCantBeFoundIsRefused() throws {
        var token = try #require(CodeSignature.ownAuditToken())
        // A process ID no process has.
        token.replaceSubrange(20..<24, with: withUnsafeBytes(of: Int32.max) { Data($0) })
        #expect(CodeSignature.process(auditToken: token) == .invalid)
    }

    @Test func knowsAnAppsOwnExecutable() {
        let app = URL(filePath: "/Applications/Example.app")
        #expect(CodeSignature.appBundle(executable: app.appending(path: "Contents/MacOS/Example"))?.path
                == app.path)
        #expect(CodeSignature.appBundle(executable: URL(filePath: "/usr/bin/open")) == nil)
        #expect(CodeSignature.appBundle(executable: app.appending(path: "Contents/Helpers/tool")) == nil)
        #expect(CodeSignature.appBundle(executable: URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"))
                == nil)
    }
}
#endif
