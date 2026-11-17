import Foundation
import Testing
@testable import ConfluxCore

@Suite struct PairedAppsTests {
    /// A file in a folder of its own, removed when the test ends.
    func withFile(_ body: (URL) async throws -> Void) async rethrows {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PairedAppsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder.appending(path: "conflux/paired-apps.json"))
    }

    func request(token: String?, path: String = "/v1/chat/completions") -> HTTPRequest {
        HTTPRequest(method: path == "/health" ? "GET" : "POST", path: path,
                    headers: token.map { [("Authorization", "Bearer \($0)")] } ?? [],
                    body: Data(#"{"messages":[]}"#.utf8))
    }

    @Test func pairingGivesEachAppItsOwnToken() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let one = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let two = try apps.pair(bundleID: "com.example.two", teamID: "TEAM000001", name: "Two")
            #expect(one.token != two.token)
            #expect(one.token.hasPrefix("cfx_"))
            #expect(apps.app(withToken: one.token)?.id == one.id)
            #expect(apps.app(withToken: two.token)?.id == two.id)
            #expect(apps.app(withToken: "cfx_wrong") == nil)
            #expect(apps.apps.map(\.name) == ["One", "Two"])
        }
    }

    @Test func pairingAgainKeepsTheToken() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let first = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let again = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One, renamed")
            #expect(again.token == first.token)
            #expect(again.paired == first.paired)
            #expect(apps.apps.map(\.name) == ["One, renamed"])
        }
    }

    @Test func anotherTeamIsAnotherApp() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let real = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let other = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000002", name: "One")
            let unsigned = try apps.pair(bundleID: "com.example.one", teamID: nil, name: "One")
            #expect(Set([real.token, other.token, unsigned.token]).count == 3)
            #expect(apps.apps.count == 3)
        }
    }

    @Test func revokingRefusesOnlyThatApp() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let one = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let two = try apps.pair(bundleID: "com.example.two", teamID: "TEAM000001", name: "Two")
            try apps.revoke(one.id)
            #expect(apps.app(withToken: one.token) == nil)
            #expect(apps.app(withToken: two.token)?.id == two.id)
            try apps.revoke("unknown")
            // Paired again, after a revoke, it gets a new token.
            let back = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            #expect(back.token != one.token)
        }
    }

    @Test func keptInAFileOnlyThisUserCanRead() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let one = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            let reread = PairedApps(url: url)
            #expect(reread.app(withToken: one.token)?.id == one.id)
            try apps.revoke(one.id)
            #expect(PairedApps(url: url).apps.isEmpty)
        }
    }

    @Test func lastUsedIsWrittenAtMostOnceAMinute() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let one = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One", at: start)
            _ = apps.app(withToken: one.token, at: start.addingTimeInterval(10))
            _ = apps.app(withToken: one.token, at: start.addingTimeInterval(30))
            // In memory, the latest.
            #expect(apps.apps.first?.lastUsed == start.addingTimeInterval(30))
            // In the file, the first, until a minute has passed.
            #expect(PairedApps(url: url).apps.first?.lastUsed == start.addingTimeInterval(10))
            _ = apps.app(withToken: one.token, at: start.addingTimeInterval(75))
            #expect(PairedApps(url: url).apps.first?.lastUsed == start.addingTimeInterval(75))
        }
    }

    @Test func theGatewayTakesAppTokensAsWellAsTheOwners() async throws {
        try await withFile { url in
            let apps = PairedApps(url: url)
            let one = try apps.pair(bundleID: "com.example.one", teamID: "TEAM000001", name: "One")
            let two = try apps.pair(bundleID: "com.example.two", teamID: "TEAM000001", name: "Two")
            let gateway = Gateway(scheduler: await Scheduler.with([FakeHost(id: "h")]), token: "owner",
                                  pairedApps: apps)
            #expect(await gateway.handle(request(token: "owner")).status == 200)
            #expect(await gateway.handle(request(token: one.token)).status == 200)
            #expect(await gateway.handle(request(token: two.token)).status == 200)
            #expect(await gateway.handle(request(token: "cfx_wrong")).status == 401)
            #expect(await gateway.handle(request(token: nil)).status == 401)

            // Revoked while the gateway runs: refused at the next request,
            // and the other app isn't.
            try apps.revoke(one.id)
            #expect(await gateway.handle(request(token: one.token)).status == 401)
            #expect(await gateway.handle(request(token: two.token)).status == 200)
            #expect(await gateway.handle(request(token: "owner")).status == 200)
            // Up, to anyone. The counts, only with a token.
            let health = await gateway.handle(request(token: one.token, path: "/health"))
            let body = try JSONSerialization.jsonObject(with: health.body) as? [String: Any]
            #expect(body?["hosts"] == nil)
        }
    }
}
