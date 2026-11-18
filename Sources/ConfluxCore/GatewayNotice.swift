import Foundation

/// The notice an app on the same Mac watches to learn that the gateway
/// changed, without asking `/health` again and again: a distributed
/// notification with nothing attached. A sandboxed app can't attach anything
/// to one, anyone can post or watch it, and it says only that something
/// changed. An app re-reads `/health` and `/v1/models` with its token.
public enum GatewayNotice {
    public static let name = "com.caseybisson.conflux.gateway.changed"

    /// The fewest seconds between two notices. Slots move under memory
    /// pressure and heat, and a burst of moves posts one notice.
    public static let interval: Duration = .seconds(1)

    /// What a notice says changed: whether the gateway listens, and where;
    /// whether its owner lets it take work; and which hosts serve which
    /// models, labelled how, with how many slots each can fill now. Not how
    /// busy they are:
    /// a request starting or finishing posts nothing.
    public struct State: Equatable, Sendable {
        public struct Host: Equatable, Sendable {
            public var id: String
            public var model: String?
            /// The model's tags, and whether it answers only when asked for:
            /// which requests reach it.
            public var tags: [String] = []
            public var onlyWhenAsked = false
            /// The slots the gateway can fill on it now, as `/health` says:
            /// none while it starts, fails, is paused or drains, or has no
            /// model, and fewer under memory pressure or heat.
            public var capacity: Int
        }

        public var port: UInt16?
        public var intent: OwnerIntent?
        public var hosts: [Host]

        /// Stopped: nothing listens.
        public static let stopped = State(port: nil, intent: nil, hosts: [])

        public init(port: UInt16?, intent: OwnerIntent?, hosts: [Host]) {
            self.port = port
            self.intent = intent
            self.hosts = hosts
        }

        /// The gateway's state, listening on `port`, or stopped, with no port.
        public init(port: UInt16?, intent: OwnerIntent, snapshot: SchedulerSnapshot?) {
            guard let port else { self = .stopped; return }
            let hosts = (snapshot?.hosts ?? [])
                .map { Host(id: $0.id, model: $0.model?.id, tags: $0.model?.tags ?? [],
                            onlyWhenAsked: $0.model?.onlyWhenAsked ?? false, capacity: $0.capacity) }
                .sorted { $0.id < $1.id }
            self.init(port: port, intent: intent, hosts: hosts)
        }
    }

    /// Decides when to post: when the state differs from what the last
    /// notice said, and at most once an `interval`. A change that comes too
    /// soon waits for the next `update` once the interval has passed, so
    /// whoever calls it calls it again at least once an interval, as the
    /// app's once-a-second loop does.
    public struct Coalescer: Sendable {
        /// The state the last notice said. conflux has just launched, so
        /// before it, nothing listened: the gateway coming up at launch
        /// posts, which is what an app that launched conflux waits for.
        private var said = State.stopped
        private var lastPost: ContinuousClock.Instant?

        public init() {}

        /// Whether to post a notice now, given the gateway's current state.
        public mutating func update(_ state: State, at now: ContinuousClock.Instant) -> Bool {
            guard state != said else { return false }
            if let lastPost, now - lastPost < GatewayNotice.interval { return false }
            self.said = state
            lastPost = now
            return true
        }

        /// Whether to post one last notice as conflux quits: when the last
        /// one said the gateway was listening. Quitting doesn't wait out the
        /// interval: no later `update` would post it.
        public mutating func quitting(at now: ContinuousClock.Instant) -> Bool {
            guard said != .stopped else { return false }
            self.said = .stopped
            lastPost = now
            return true
        }
    }
}
