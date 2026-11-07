import Foundation

/// Something that runs chat completions for one model: in Phase 1, a
/// supervised `llama-server` on this Mac. Hosts on other devices, reached over
/// iroh, implement the same protocol later.
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
    /// Gone.
    case offline
}

/// What a runtime answered: a status, and the body to pass on.
public struct HostReply: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum HostError: Error, Equatable {
    /// Nothing answered: refused, reset, timed out, or the runtime is down.
    /// The request may go to another host.
    case unavailable(String)
    /// The runtime answered with a server error. The request may go to
    /// another host.
    case failed(status: Int, message: String)
}
