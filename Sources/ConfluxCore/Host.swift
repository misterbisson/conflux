import Foundation

/// Something that runs chat completions for one model: this Mac's own
/// runtime, or another device's host reached over iroh (`RemoteHost`).
public protocol InferenceHost: AnyObject, Sendable {
    var id: String { get }
    /// Nil until the host has loaded its model and knows what it serves.
    var model: ModelInfo? { get async }
    /// How many requests the host runs at once when nothing limits it.
    var slots: Int { get }
    /// Whether the host can take work, and if not, why.
    var availability: HostAvailability { get async }
    /// Runs one OpenAI chat completion request body and returns the runtime's
    /// response. Throws `HostError` when the runtime couldn't answer.
    func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply
    /// The same, with what the scheduler says about the request.
    func complete(_ body: Data, timeout: TimeInterval, options: RequestOptions) async throws -> HostReply
    /// For a host on another device, whose slots other gateways share: what
    /// it last said about its slots. Nil for a host whose slots the
    /// scheduler holds itself.
    var report: HostReport? { get async }
    /// What kind of device the host runs on. This device's own for a host
    /// here; for a host on another device, what it last said, or nil if it
    /// hasn't, as peers from before it was reported don't.
    var hardware: HardwareInfo? { get }
    /// Calls `changed` whenever the host's model, availability or report may
    /// have changed, so the scheduler needn't wait for its next look.
    func observe(_ changed: @escaping @Sendable () -> Void)
    /// Stops the request sent with this ID, if it's still running or
    /// waiting: a hedged copy that lost. For a host the scheduler runs
    /// itself, cancelling the request's task does this instead.
    func cancel(_ id: UUID) async
}

extension InferenceHost {
    public func complete(_ body: Data, timeout: TimeInterval, options: RequestOptions) async throws -> HostReply {
        try await complete(body, timeout: timeout)
    }
    public var report: HostReport? { get async { nil } }
    public var hardware: HardwareInfo? { HardwareInfo.current }
    public func observe(_ changed: @escaping @Sendable () -> Void) {}
    public func cancel(_ id: UUID) async {}
}

/// What the scheduler says about one request when it sends it to a host.
public struct RequestOptions: Sendable, Equatable {
    /// Names this copy of the request, so it can be cancelled.
    public var id: UUID
    /// The request may wait on the host for its next free slot: it was sent
    /// ahead, so that a slot freeing up doesn't wait for a round trip.
    public var prefetch: Bool

    public init(id: UUID = UUID(), prefetch: Bool = false) {
        self.id = id
        self.prefetch = prefetch
    }
}

/// What a host on another device last said about its slots.
public struct HostReport: Sendable, Equatable {
    /// Slots free when it reported: the ones it takes work in, less those
    /// running or holding a request.
    public var free: Int
    /// Requests sent ahead and waiting there for a slot.
    public var held: Int
    /// Seconds it has had a free slot since it started, by its own count.
    /// Nil from hosts that don't count.
    public var freeSeconds: Double?
    /// Whether it tells changes as they happen and holds a request sent
    /// ahead. Hosts from before host pull don't.
    public var pulls: Bool
    /// When the report arrived.
    public var at: Date

    public init(free: Int, held: Int = 0, freeSeconds: Double? = nil, pulls: Bool = true, at: Date = Date()) {
        self.free = free
        self.held = held
        self.freeSeconds = freeSeconds
        self.pulls = pulls
        self.at = at
    }
}

public enum HostAvailability: Sendable, Equatable {
    case available
    /// Loading, or restarting after a crash. Expected to come back.
    case starting(String)
    /// Can't take work until something changes: a failed self-check, a
    /// runtime that keeps exiting.
    case failed(String)
    /// Up, but taking no work: its owner paused or drained it, or resource
    /// policy did. Reported by hosts on other devices.
    case paused(String)
    /// Gone.
    case offline
}

/// What a runtime answered: a status, and the body to pass on.
public struct HostReply: Sendable, Equatable {
    public var status: Int
    public var body: Data
    /// What ran, when the host says. A host on another device does, since its
    /// model can change between the gateway's last look and the answer.
    public var model: ModelInfo?
    /// A refusal from this host that another host might not give: the model
    /// declined the content, the request was too long for it, or it asked
    /// for something this runtime doesn't do. The gateway tries another
    /// host that serves an accepted model, and passes this on only when
    /// there's none.
    public var retryElsewhere: Bool

    public init(status: Int, body: Data, model: ModelInfo? = nil, retryElsewhere: Bool = false) {
        self.status = status
        self.body = body
        self.model = model
        self.retryElsewhere = retryElsewhere
    }
}

public enum HostError: Error, Equatable {
    /// Nothing answered: refused, reset, timed out, or the runtime is down.
    /// The request may go to another host.
    case unavailable(String)
    /// The runtime answered with a server error. The request may go to
    /// another host.
    case failed(status: Int, message: String)
    /// The host is up but has no free slot: another gateway took it first.
    /// The request goes to another host, and this one isn't counted as
    /// failing.
    case busy(String)
    /// The scheduler cancelled it: a hedged copy that lost. Not a failure.
    case cancelled

    /// Counts against the host, as `FailureCounts.hostFaults` does: it
    /// didn't answer, or its runtime answered with a server error.
    var isHostFault: Bool {
        switch self {
        case .unavailable, .failed: true
        case .busy, .cancelled: false
        }
    }
}
