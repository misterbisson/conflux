import Foundation
import Testing
@testable import ConfluxCore

@Suite struct GatewayNoticeTests {
    typealias State = GatewayNotice.State
    typealias Host = GatewayNotice.State.Host

    static let model = ModelInfo(id: "qwen", capabilities: [.text], fingerprint: "llama.cpp b1 abc")
    static let local = Host(id: "local", model: "qwen", capacity: 2)
    static let peer = Host(id: "peer", model: "qwen", capacity: 4)
    static let serving = State(port: 8090, intent: .serving, hosts: [local])

    /// The coalescer, as a reference, so `#expect` can call it.
    final class Notice {
        var coalescer = GatewayNotice.Coalescer()
        func update(_ state: State, at now: ContinuousClock.Instant) -> Bool { coalescer.update(state, at: now) }
        func quitting(at now: ContinuousClock.Instant) -> Bool { coalescer.quitting(at: now) }
    }

    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    /// A coalescer that has said `state`, at time 0.
    func said(_ state: State) -> Notice {
        let notice = Notice()
        #expect(notice.update(state, at: at(0)))
        return notice
    }

    @Test func theGatewayComingUpAtLaunchPosts() {
        let notice = Notice()
        #expect(notice.update(Self.serving, at: at(0)))
    }

    @Test func stoppedAtLaunchPostsNothing() {
        let notice = Notice()
        #expect(!notice.update(.stopped, at: at(0)))
        #expect(!notice.update(.stopped, at: at(5)))
    }

    @Test func nothingChangedPostsNothing() {
        let notice = said(Self.serving)
        #expect(!notice.update(Self.serving, at: at(2)))
        #expect(!notice.update(Self.serving, at: at(3)))
    }

    @Test(arguments: [
        State(port: 8091, intent: .serving, hosts: [local]),          // a new port
        State(port: 8090, intent: .draining, hosts: [local]),         // drained
        State(port: 8090, intent: .paused, hosts: [local]),           // paused
        State(port: 8090, intent: .serving, hosts: [local, peer]),    // a Mac joined
        State(port: 8090, intent: .serving, hosts: []),               // a Mac left
        State(port: 8090, intent: .serving,                           // another model
              hosts: [Host(id: "local", model: "gemma", capacity: 2)]),
        State(port: 8090, intent: .serving,                           // slots moved
              hosts: [Host(id: "local", model: "qwen", capacity: 1)]),
        State(port: 8090, intent: .serving, hosts: [local],           // no token asked for
              requiresToken: false),
        State(port: 8090, intent: .serving, hosts: [local],           // an app paired
              apps: ["TEAM000001.com.example.client"]),
        State.stopped,                                                // stopped
    ])
    func eachChangePosts(_ changed: State) {
        let notice = said(Self.serving)
        #expect(notice.update(changed, at: at(2)))
        #expect(!notice.update(changed, at: at(4)))
    }

    @Test func revokingAnAppPosts() {
        let both = ["TEAM000001.com.example.client", "-.com.example.other"]
        let notice = said(State(port: 8090, intent: .serving, hosts: [Self.local], apps: both))
        // The same apps, listed in another order, are no change.
        #expect(!notice.update(State(port: 8090, intent: .serving, hosts: [Self.local], apps: both.reversed()),
                               at: at(2)))
        #expect(notice.update(State(port: 8090, intent: .serving, hosts: [Self.local], apps: [both[1]]),
                              at: at(3)))
    }

    @Test func resumingAfterAPausePosts() {
        let notice = said(State(port: 8090, intent: .paused, hosts: [Self.local]))
        #expect(notice.update(Self.serving, at: at(2)))
    }

    @Test func aBurstOfSlotChangesPostsOnce() {
        let notice = said(Self.serving)
        var posts = 0
        // Memory pressure moves the slots ten times in under a second.
        for step in 1...10 {
            let state = State(port: 8090, intent: .serving,
                              hosts: [Host(id: "local", model: "qwen", capacity: step % 3)])
            if notice.update(state, at: at(2 + Double(step) * 0.09)) { posts += 1 }
        }
        #expect(posts == 1)
    }

    @Test func aChangeTooSoonPostsOnceTheSecondIsUp() {
        let notice = said(Self.serving)
        let drained = State(port: 8090, intent: .draining, hosts: [Self.local])
        #expect(!notice.update(drained, at: at(0.4)))
        #expect(!notice.update(drained, at: at(0.9)))
        #expect(notice.update(drained, at: at(1.0)))
        #expect(!notice.update(drained, at: at(2.0)))
    }

    @Test func aChangeUndoneBeforeItPostsPostsNothing() {
        let notice = said(Self.serving)
        let fewer = State(port: 8090, intent: .serving, hosts: [Host(id: "local", model: "qwen", capacity: 1)])
        #expect(!notice.update(fewer, at: at(0.5)))
        #expect(!notice.update(Self.serving, at: at(1.5)))
    }

    @Test func quittingPostsWhileListening() {
        let notice = said(Self.serving)
        // Even within a second of the last notice: no later one would come.
        #expect(notice.quitting(at: at(0.1)))
        #expect(!notice.quitting(at: at(0.2)))
    }

    @Test func quittingStoppedPostsNothing() {
        let notice = Notice()
        #expect(!notice.quitting(at: at(0)))
        let stopped = said(Self.serving)
        #expect(stopped.update(.stopped, at: at(2)))
        #expect(!stopped.quitting(at: at(3)))
    }

    @Test func theStateIsWhatClientsReadNotHowBusyItIs() {
        func snapshot(active: Int, completed: Int) -> SchedulerSnapshot {
            SchedulerSnapshot(
                hosts: [HostSnapshot(id: "peer", model: Self.model, state: .busy, slots: 4, capacity: 4,
                                     active: active, completed: completed),
                        HostSnapshot(id: "local", model: Self.model, state: .ready, slots: 2, capacity: 2)],
                queued: active, completed: completed, failures: FailureCounts(), rejected: 0, busy: 0,
                unavailable: 0, hedged: 0, hedgeWins: 0, perHour: 0, idleWithWorkSeconds: 0)
        }
        let quiet = State(port: 8090, intent: .serving, snapshot: snapshot(active: 0, completed: 0),
                          requiresToken: true, apps: [])
        let busy = State(port: 8090, intent: .serving, snapshot: snapshot(active: 4, completed: 90),
                         requiresToken: true, apps: [])
        #expect(quiet == busy)
        #expect(quiet.hosts == [Self.local, Self.peer])
    }

    @Test func noPortIsStopped() {
        let snapshot = SchedulerSnapshot(
            hosts: [HostSnapshot(id: "local", model: Self.model, state: .ready, slots: 2, capacity: 2)],
            queued: 0, completed: 0, failures: FailureCounts(), rejected: 0, busy: 0, unavailable: 0, hedged: 0,
            hedgeWins: 0, perHour: 0, idleWithWorkSeconds: 0)
        #expect(State(port: nil, intent: .serving, snapshot: snapshot, requiresToken: false, apps: ["-.com.example.client"])
                == .stopped)
        #expect(State(port: 8090, intent: .serving, snapshot: nil, requiresToken: true, apps: []).hosts.isEmpty)
    }
}
