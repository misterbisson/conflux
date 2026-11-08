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

    public init(status: Int, body: Data, model: ModelInfo? = nil) {
        self.status = status
        self.body = body
        self.model = model
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
}
