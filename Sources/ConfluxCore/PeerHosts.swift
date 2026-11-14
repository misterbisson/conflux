import Foundation

/// Every host one peer serves, in this gateway's scheduler: a model file's
/// and Apple's model, say.
///
/// The peer answers for its first host without being told which, as peers
/// always have, so that one is a `RemoteHost` from the start. Its status
/// lists the peer's other hosts (`HostStatus.hosts`), and each of those
/// joins the scheduler as a `RemoteHost` of its own, naming its host on the
/// peer, and leaves when the peer stops listing it. A peer from before it
/// could serve more than one lists none, and is one host, as before.
final class PeerHosts: @unchecked Sendable {
    let endpointID: String
    /// The host the peer answers for by default.
    let primary: RemoteHost
    private let link: any PeerLink
    private let scheduler: Scheduler
    private let lock = NSLock()
    /// The peer's other hosts, by their IDs on the peer.
    private var others: [String: RemoteHost] = [:]
    private var interval: Duration = .seconds(1)
    private var stopped = false
    /// Changes to `others`, one at a time, in the order the peer made them.
    private var following: Task<Void, Never>?

    init(endpointID: String, link: any PeerLink, scheduler: Scheduler) {
        self.endpointID = endpointID
        self.link = link
        self.scheduler = scheduler
        primary = RemoteHost(endpointID: endpointID, link: link)
    }

    /// The peer's hosts, the one it answers for by default first.
    var hosts: [RemoteHost] {
        lock.withLock { [primary] + others.keys.sorted().compactMap { others[$0] } }
    }

    /// Adds the peer's first host to the scheduler and starts asking for its
    /// status, which brings in the rest. `interval` is for peers that
    /// answer at once.
    func start(every interval: Duration = .seconds(1)) async {
        lock.withLock { self.interval = interval }
        primary.observeOthers { [weak self] listed in self?.follow(listed) }
        primary.start(every: interval)
        await scheduler.add(primary)
    }

    private func follow(_ listed: [String]) {
        lock.withLock {
            guard !stopped else { return }
            let previous = following
            following = Task { [weak self] in
                await previous?.value
                await self?.apply(listed)
            }
        }
    }

    /// Makes the scheduler hold exactly the hosts the peer lists.
    private func apply(_ listed: [String]) async {
        let (added, removed, interval) = lock.withLock { () -> ([RemoteHost], [RemoteHost], Duration) in
            guard !stopped else { return ([], [], self.interval) }
            let wanted = Set(listed)
            let removed = others.filter { !wanted.contains($0.key) }.map(\.value)
            for host in removed { others[host.hostOnPeer ?? ""] = nil }
            let added = listed.filter { others[$0] == nil }.map {
                RemoteHost(endpointID: endpointID, link: link, hostOnPeer: $0)
            }
            for host in added { others[host.hostOnPeer ?? ""] = host }
            return (added, removed, self.interval)
        }
        for host in removed {
            host.stop()
            await scheduler.remove(hostID: host.id)
        }
        for host in added {
            await scheduler.add(host)
            host.start(every: interval)
        }
    }

    /// Stops asking the peer and takes its hosts out of the scheduler.
    func stop() async {
        let following = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            return self.following
        }
        // Whatever it was adding is added before it's all taken out.
        await following?.value
        primary.stop()
        let all = lock.withLock { () -> [RemoteHost] in
            defer { others = [:] }
            return [primary] + others.values
        }
        for host in all {
            host.stop()
            await scheduler.remove(hostID: host.id)
        }
    }
}
