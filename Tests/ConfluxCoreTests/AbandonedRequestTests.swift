import Foundation
@preconcurrency import Network
import Testing
@testable import ConfluxCore

/// A request whose client has gone stops, and its slot goes to work that's
/// still wanted.
@Suite struct AbandonedRequestTests {
    let any = ModelChoice(model: nil, preference: nil)

    /// A host whose first request runs for a minute unless it's cancelled,
    /// and whose others answer at once.
    static func slowFirst(id: String = "h") -> FakeHost {
        FakeHost(id: id) { call in
            if call == 1 { try await Task.sleep(for: .seconds(60)) }
            return HostReply(status: 200, body: FakeHost.okBody)
        }
    }

    @Test func aCancelledRequestFreesItsSlotForTheNext() async {
        let host = Self.slowFirst()
        let scheduler = await Scheduler.with([host])
        let abandoned = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { host.callCount == 1 })
        let next = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().queued == 1 })

        let started = Date()
        abandoned.cancel()
        #expect(await abandoned.value == .cancelled)
        let outcome = await next.value
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(Date().timeIntervalSince(started) < 5)

        // Not the host's failure, and not an answer of busy.
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.failures.total == 0)
        #expect(snapshot.hosts.first?.failures.total == 0)
        #expect(snapshot.hosts.first?.state == .ready)
        #expect(snapshot.hosts.first?.completed == 1)
        #expect(snapshot.busy == 0)
        #expect(host.callCount == 2)
    }

    @Test func aCancelledRequestLeavesTheQueue() async {
        let host = Self.slowFirst()
        let scheduler = await Scheduler.with([host])
        let running = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { host.callCount == 1 })
        let waiting = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().queued == 1 })

        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        #expect(await scheduler.snapshot().queued == 0)
        #expect(await scheduler.snapshot().busy == 0)
        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(host.callCount == 1)
    }

    /// Clients sending the same key share one request. One leaving doesn't
    /// stop it for the others.
    @Test func aSharedRequestRunsOnForClientsStillWaiting() async {
        let gate = Gate()
        let host = FakeHost(id: "h", behavior: gate.reply())
        let scheduler = await Scheduler.with([host])
        let leaving = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") }
        #expect(await eventually { host.callCount == 1 })
        let staying = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") }
        #expect(await eventually { await scheduler.clients(waitingFor: "k") == 2 })

        leaving.cancel()
        #expect(await leaving.value == .cancelled)
        #expect(await scheduler.clients(waitingFor: "k") == 1)
        await gate.release()
        let outcome = await staying.value
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(host.callCount == 1)
    }

    /// Once every client sharing a request has left, it stops, and the key
    /// starts it again.
    @Test func aSharedRequestStopsWhenEveryClientLeaves() async {
        let host = Self.slowFirst()
        let scheduler = await Scheduler.with([host])
        let first = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") }
        let second = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: "k") }
        #expect(await eventually { await scheduler.clients(waitingFor: "k") == 2 && host.callCount == 1 })

        first.cancel()
        second.cancel()
        #expect(await first.value == .cancelled)
        #expect(await second.value == .cancelled)
        #expect(await eventually(within: 5) { await scheduler.snapshot().hosts.first?.active == 0 })
        #expect(await scheduler.snapshot().failures.total == 0)

        let again = await scheduler.submit(Data(), choice: any, deadline: nil, key: "k")
        if case .completed = again {} else { Issue.record("\(again)") }
        #expect(host.callCount == 2)
    }

    /// A hedged request stops both copies.
    @Test func aCancelledHedgedRequestStopsEveryCopy() async {
        let slow = FakeHost(id: "slow") { _ in
            try await Task.sleep(for: .seconds(60))
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        let other = FakeHost(id: "other") { _ in
            try await Task.sleep(for: .seconds(60))
            return HostReply(status: 200, body: FakeHost.okBody)
        }
        var config = SchedulerConfig()
        config.hedgeAfter = 1
        let scheduler = await Scheduler.with([slow, other], config: config)
        await scheduler.setTypical(0.05, for: "slow")
        await scheduler.setTypical(0.05, for: "other")
        let request = Task { await scheduler.submit(Data(), choice: any, deadline: nil, key: nil) }
        #expect(await eventually { await scheduler.snapshot().hedged == 1 })

        request.cancel()
        #expect(await request.value == .cancelled)
        #expect(await eventually(within: 5) { await scheduler.snapshot().hosts.allSatisfy { $0.active == 0 } })
        #expect(await scheduler.snapshot().failures.total == 0)
    }
}

@Suite struct ClosedConnectionTests {
    static func post(_ path: String = "/v1/chat/completions", body: String = #"{"messages":[]}"#) -> String {
        "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    /// The gateway stops a request whose client closed the connection, and
    /// the next request has the slot at once.
    @Test func aClientThatClosesFreesItsSlot() async throws {
        let host = AbandonedRequestTests.slowFirst()
        let scheduler = await Scheduler.with([host])
        let gateway = Gateway(scheduler: scheduler, token: nil)
        let server = HTTPServer { await gateway.handle($0) }
        let port = try await server.start(port: 0)
        defer { server.stop() }

        let client = try await RawClient(port: port)
        try await client.send(Self.post())
        #expect(await eventually { host.callCount == 1 })
        client.close()
        #expect(await eventually(within: 5) { await scheduler.snapshot().hosts.first?.active == 0 })
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.failures.total == 0)
        #expect(snapshot.hosts.first?.state == .ready)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                                 timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"messages":[]}"#.utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    /// Requests a client sends on a keep-alive connection while one is being
    /// handled, pipelined, are kept, and answered in turn.
    @Test func requestsSentWhileOneRunsAreAnsweredInTurn() async throws {
        let gate = Gate()
        let started = Flag()
        let server = HTTPServer { request in
            if request.path == "/slow" {
                started.set()
                await gate.wait()
            }
            return HTTPResponse(status: 200, body: Data("done\(request.path)".utf8))
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }

        let client = try await RawClient(port: port)
        try await client.send(Self.post("/slow"))
        #expect(await eventually { started.isSet })
        try await client.send(Self.post("/first") + Self.post("/second"))
        await gate.release()
        let text = await client.read { $0.contains("done/second") }
        let order = ["done/slow", "done/first", "done/second"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 3)
        #expect(order == order.sorted())
        client.close()
    }
}

/// Set once, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// A TCP client that sends and closes when a test says, unlike URLSession.
final class RawClient: @unchecked Sendable {
    let connection: NWConnection

    init(port: UInt16) async throws {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.client"))
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// What arrives until `done` holds of it, the connection ends, or 10 seconds pass.
    func read(until done: (String) -> Bool) async -> String {
        var received = Data()
        let deadline = Date().addingTimeInterval(10)
        while !done(String(decoding: received, as: UTF8.self)), Date() < deadline {
            guard let more = await receive() else { break }
            received.append(more)
        }
        return String(decoding: received, as: UTF8.self)
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete || error != nil ? nil : Data())
                }
            }
        }
    }

    func close() { connection.cancel() }
}
