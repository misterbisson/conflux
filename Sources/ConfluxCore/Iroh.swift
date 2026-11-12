import AppleIroh
import Foundation

/// apple-iroh's C ABI, in Swift. One endpoint per process: apple-iroh keeps it
/// in a global, so `Mesh` is the only caller.
enum Iroh {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let code: Int32
        let call: String

        var description: String {
            let what = switch code {
            case APPLE_IROH_ERR_NOT_STARTED: "the endpoint isn't started"
            case APPLE_IROH_ERR_ALREADY_STARTED: "the endpoint is already started"
            case APPLE_IROH_ERR_BIND: "couldn't bind the endpoint"
            case APPLE_IROH_ERR_BAD_ID: "not an endpoint ID"
            case APPLE_IROH_ERR_CONNECT: "couldn't connect"
            case APPLE_IROH_ERR_BUFFER: "buffer too small"
            case APPLE_IROH_ERR_NO_REMOTE: "no connection to that endpoint"
            case APPLE_IROH_ERR_BAD_KEY: "not a secret key"
            case APPLE_IROH_ERR_CLOSED: "the connection closed"
            case APPLE_IROH_ERR_STREAM: "a stream failed"
            case APPLE_IROH_ERR_PORT: "couldn't bind a loopback port"
            case APPLE_IROH_ERR_PATH: "not a usable socket path"
            default: "error \(code)"
            }
            return "\(call): \(what)"
        }
    }

    @discardableResult
    private static func check(_ code: Int32, _ call: String) throws(Failure) -> Int32 {
        guard code >= 0 else { throw Failure(code: code, call: call) }
        return code
    }

    /// Binds the endpoint under this device's key, so its ID is the same on
    /// every launch. Nobody may connect in until `allow`.
    static func start(secretKey: Data) throws(Failure) {
        let code = secretKey.withUnsafeBytes { bytes in
            apple_iroh_start_with_secret(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
        }
        try check(code, "start")
    }

    static var endpointID: String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let written = apple_iroh_endpoint_id(&buffer, Int32(buffer.count))
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func allow(_ id: String) throws(Failure) {
        try check(apple_iroh_allow(id), "allow")
    }

    static func allowNone() { apple_iroh_allow_none() }

    /// Incoming connections refused because they weren't allowed.
    static var refused: Int { Int(max(0, apple_iroh_refused())) }

    /// Dials a remote and holds the connection. Blocks for seconds: never on
    /// the main thread or the cooperative pool.
    static func connect(_ id: String) throws(Failure) {
        try check(apple_iroh_connect(id), "connect")
    }

    /// RELAY | DIRECT bits for a held connection. Throws `CLOSED` once it has
    /// closed, including when the other side refused it.
    static func path(_ id: String) throws(Failure) -> Int32 {
        try check(apple_iroh_path(id), "path")
    }

    /// The path the held connection sends on, and its round trip.
    static func selected(_ id: String) -> (path: Int32, rtt: Duration)? {
        var rtt: Int32 = 0
        let path = apple_iroh_selected(id, &rtt)
        guard path >= 0 else { return nil }
        return (path, .microseconds(Int64(rtt)))
    }

    /// A loopback port whose connections reach the remote's exposed port. The
    /// same port for the same remote, across redials.
    static func forward(_ id: String) throws(Failure) -> UInt16 {
        var port: Int32 = 0
        try check(apple_iroh_forward(id, &port), "forward")
        return UInt16(clamping: port)
    }

    /// The one loopback port remotes' forwards reach. Zero exposes nothing.
    static func expose(_ port: UInt16) throws(Failure) {
        try check(apple_iroh_expose(Int32(port)), "expose")
    }

    /// The one Unix socket remotes' forwards reach, instead of a port: out of
    /// other apps' reach in this app's container.
    static func expose(socket path: String) throws(Failure) {
        try check(apple_iroh_expose_unix(path), "expose")
    }

    static func stop() { apple_iroh_stop() }
}
