import AppleIroh
import Foundation

/// This device's place in the mesh: its iroh endpoint, the peers it trusts,
/// and a link to each peer's host.
///
/// Trust is symmetric and explicit. A peer is an endpoint ID this device was
/// given, by hand or from the device directory: it may connect in, and this
/// device dials it to use its host. Nobody else may connect (docs/design.md,
/// *Trust*).
///
/// Peers can be added while it runs. apple-iroh can't take one ID off its
/// allow list, or close one peer's connection, so removing a peer means a new
/// mesh.
final class Mesh: @unchecked Sendable {
    let identity: DeviceIdentity
    private let lock = NSLock()
    private var links: [String: IrohLink]
    private static let running = NSLock()
    nonisolated(unsafe) private static var started = false

    /// Where peers' streams reach this device's host service.
    enum Exposure: Equatable {
        /// A loopback port, which any process here can also reach.
        case port(UInt16)
        /// A Unix socket in this app's container, which only this app can.
        case socket(String)
    }

    /// Starts the endpoint under this device's key, allows `peers` in, and
    /// exposes the host service to them. One mesh per process: apple-iroh
    /// keeps its endpoint in a global.
    init(identity: DeviceIdentity, peers: [String], exposing exposure: Exposure?) throws {
        try Self.running.withLock {
            guard !Self.started else { throw MeshError.alreadyRunning }
            try Iroh.start(secretKey: identity.secretKey)
            do {
                guard Iroh.endpointID == identity.endpointID else { throw MeshError.identityMismatch }
                Iroh.allowNone()
                for peer in peers { try Iroh.allow(peer) }
                switch exposure {
                case .port(let port)?: try Iroh.expose(port)
                case .socket(let path)?: try Iroh.expose(socket: path)
                case nil: break
                }
            } catch {
                Iroh.stop()
                throw error
            }
            Self.started = true
        }
        self.identity = identity
        links = Dictionary(peers.map { ($0, IrohLink(endpointID: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    var peers: [String] { lock.withLock { links.keys.sorted() } }

    func link(to peer: String) -> (any PeerLink)? { lock.withLock { links[peer] } }

    /// Lets more peers in while running: apple-iroh checks its allow list as
    /// each connection arrives.
    func allow(_ added: [String]) throws {
        try lock.withLock {
            for peer in added where links[peer] == nil {
                try Iroh.allow(peer)
                links[peer] = IrohLink(endpointID: peer)
            }
        }
    }

    /// Incoming connections refused since the endpoint started: devices that
    /// aren't peers.
    var refused: Int { Iroh.refused }

    /// How each connection is carried now, for the window.
    func path(to peer: String) -> PeerPath {
        guard (try? Iroh.path(peer)) != nil, let selected = Iroh.selected(peer) else { return .none }
        switch selected.path {
        case APPLE_IROH_PATH_DIRECT: return .direct(selected.rtt)
        case APPLE_IROH_PATH_RELAY: return .relay(selected.rtt)
        default: return .none
        }
    }

    func stop() {
        Self.running.withLock {
            guard Self.started else { return }
            Iroh.stop()
            Self.started = false
        }
    }
}

public enum PeerPath: Sendable, Equatable {
    case none
    case relay(Duration)
    case direct(Duration)

    public var label: String {
        func ms(_ rtt: Duration) -> String {
            let value = Double(rtt.components.seconds) * 1000 + Double(rtt.components.attoseconds) / 1e15
            return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
        }
        switch self {
        case .none: return "not connected"
        case .relay(let rtt): return "relayed, \(ms(rtt))"
        case .direct(let rtt): return "direct, \(ms(rtt))"
        }
    }
}

enum MeshError: Error, CustomStringConvertible {
    case alreadyRunning
    case identityMismatch

    var description: String {
        switch self {
        case .alreadyRunning: "the iroh endpoint is already running in this process"
        case .identityMismatch: "iroh's endpoint ID doesn't match this device's key"
        }
    }
}

/// A connection to one peer, dialled when first needed and again when lost.
/// Dialling blocks for seconds, so it runs on its own thread, one dial at a
/// time, backing off while the peer can't be reached.
actor IrohLink: PeerLink {
    let endpointID: String
    private var port: UInt16?
    private var dial: Task<UInt16, Error>?
    private var failures = 0
    private var notBefore = Date.distantPast
    private(set) var problem: String?

    init(endpointID: String) { self.endpointID = endpointID }

    func url() async throws -> URL {
        if let port, (try? Iroh.path(endpointID)) != nil { return Self.url(port) }
        if dial == nil {
            guard Date() >= notBefore else { throw MeshFailure(description: problem ?? "unreachable") }
            let id = endpointID
            dial = Task.detached {
                try await withCheckedThrowingContinuation { continuation in
                    Thread.detachNewThread {
                        do {
                            // A peer that dialled this device left a
                            // connection both ends can forward over, and
                            // dialling it too would make a second. A peer
                            // known but not connected, after a failed dial,
                            // has none to forward over.
                            if (try? Iroh.path(id)) != nil, let port = try? Iroh.forward(id) {
                                return continuation.resume(returning: port)
                            }
                            try Iroh.connect(id)
                            continuation.resume(returning: try Iroh.forward(id))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
        do {
            let port = try await dial!.value
            self.port = port
            dial = nil
            failures = 0
            problem = nil
            return Self.url(port)
        } catch {
            dial = nil
            failures += 1
            problem = "\(error)"
            notBefore = Date().addingTimeInterval(min(30, pow(2, Double(failures))))
            throw error
        }
    }

    var connected: Bool { port != nil && (try? Iroh.path(endpointID)) != nil }

    nonisolated func reconnect() {
        Task { await self.dropIfClosed() }
    }

    private func dropIfClosed() {
        if (try? Iroh.path(endpointID)) == nil { port = nil }
    }

    static func url(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
}

struct MeshFailure: Error, CustomStringConvertible {
    let description: String
}
