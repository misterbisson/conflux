import Foundation

/// A parsed HTTP/1.1 request. Header names are matched case-insensitively.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The path, without the query string.
    public var path: String
    public var version: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(method: String, path: String, version: String = "HTTP/1.1",
                headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.path = path
        self.version = version
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// HTTP/1.1 keeps the connection open unless asked not to. HTTP/1.0 closes
    /// it unless asked to keep it.
    public var keepAlive: Bool {
        let connection = header("Connection")?.lowercased() ?? ""
        return version == "HTTP/1.0" ? connection.contains("keep-alive") : !connection.contains("close")
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.version == rhs.version
            && lhs.body == rhs.body && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// Bytes of a file to send after the head, in place of `body`: read and
    /// sent a chunk at a time, so a file of gigabytes takes no more memory
    /// than one chunk.
    public var file: FileBody?

    /// A run of bytes in a file on this device.
    public struct FileBody: Sendable, Equatable {
        public var path: String
        public var offset: Int64
        public var length: Int64

        public init(path: String, offset: Int64 = 0, length: Int64) {
            self.path = path
            self.offset = offset
            self.length = length
        }
    }

    public init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data(),
                file: FileBody? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.file = file
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func json(_ status: Int, _ object: Any, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    /// The bytes on the wire, with Content-Length and Connection added. With
    /// a file body, only the head: the server sends the file after it.
    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (name, value) in headers where !["content-length", "connection"].contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(file?.length ?? Int64(body.count))\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return file == nil ? Data(head.utf8) + body : Data(head.utf8)
    }

    public static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.file == rhs.file
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status \(status)"
        }
    }
}

/// An incremental HTTP/1.1 request parser: hand it everything received so
/// far, and it says whether a whole request is there yet.
public enum HTTPParser {
    public enum Result: Equatable {
        /// More bytes needed. `expectsContinue` is true once the headers are
        /// in and the client asked for `100 Continue` before sending its body.
        case incomplete(expectsContinue: Bool)
        case request(HTTPRequest, consumed: Int)
        /// The request can't be served. Answer with this status and close.
        case failure(status: Int, message: String)
    }

    public static let maxHeaderBytes = 64 * 1024

    public static func parse(_ buffer: Data, maxBodyBytes: Int) -> Result {
        let bytes = [UInt8](buffer)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            return bytes.count > maxHeaderBytes
                ? .failure(status: 431, message: "request headers are too large")
                : .incomplete(expectsContinue: false)
        }
        guard headerEnd <= maxHeaderBytes else {
            return .failure(status: 431, message: "request headers are too large")
        }
        let head = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { return .failure(status: 400, message: "malformed request line") }
        let version = String(requestLine[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(status: 505, message: "only HTTP/1.1 is supported")
        }
        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, message: "malformed header line")
            }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        let target = String(requestLine[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var request = HTTPRequest(method: String(requestLine[0]), path: path, version: version, headers: headers)
        let bodyStart = headerEnd + 4
        let expectsContinue = request.header("Expect")?.lowercased() == "100-continue"

        if let encoding = request.header("Transfer-Encoding")?.lowercased(), encoding != "identity" {
            guard encoding == "chunked" else {
                return .failure(status: 501, message: "unsupported transfer encoding: \(encoding)")
            }
            switch dechunk(bytes, from: bodyStart, maxBodyBytes: maxBodyBytes) {
            case .incomplete: return .incomplete(expectsContinue: expectsContinue)
            case .failure(let status, let message): return .failure(status: status, message: message)
            case .body(let body, let end):
                request.body = body
                return .request(request, consumed: end)
            }
        }

        let length: Int
        if let text = request.header("Content-Length") {
            guard let value = Int(text), value >= 0 else { return .failure(status: 400, message: "bad Content-Length") }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .failure(status: 413, message: "request body is too large") }
        guard bytes.count - bodyStart >= length else { return .incomplete(expectsContinue: expectsContinue) }
        request.body = Data(bytes[bodyStart..<(bodyStart + length)])
        return .request(request, consumed: bodyStart + length)
    }

    enum Chunked {
        case incomplete
        case failure(Int, String)
        case body(Data, end: Int)
    }

    static func dechunk(_ bytes: [UInt8], from start: Int, maxBodyBytes: Int) -> Chunked {
        var body = Data()
        var position = start
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: position) else { return .incomplete }
            let sizeText = String(decoding: bytes[position..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .failure(400, "bad chunk size") }
            position = lineEnd + 2
            if size == 0 {
                // Skip any trailers, up to the blank line that ends the body.
                while true {
                    guard let end = find([13, 10], in: bytes, from: position) else { return .incomplete }
                    if end == position { return .body(body, end: end + 2) }
                    position = end + 2
                }
            }
            guard body.count + size <= maxBodyBytes else { return .failure(413, "request body is too large") }
            guard bytes.count >= position + size + 2 else { return .incomplete }
            body.append(contentsOf: bytes[position..<(position + size)])
            position += size + 2
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0] && Array(haystack[index..<(index + needle.count)]) == needle {
                return index
            }
            index += 1
        }
        return nil
    }
}

/// What a `Range` header asks of a file: one range, `bytes=N-` or
/// `bytes=N-M`. Anything else, several ranges included, is ignored and the
/// whole file is sent, as HTTP allows.
enum RangeRequest: Equatable {
    case whole
    case part(offset: Int64, length: Int64)
    /// It starts past the end of the file.
    case unsatisfiable

    static func parse(_ header: String?, size: Int64) -> RangeRequest {
        guard let header else { return .whole }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = text.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        func number(_ text: Substring) -> Int64? {
            let digits = text.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(digits)
        }
        guard let start = number(spec[..<dash]) else { return .whole }
        let last = spec[spec.index(after: dash)...]
        var end = size - 1
        if !last.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = number(last), value >= start else { return .whole }
            end = min(value, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .part(offset: start, length: end - start + 1)
    }
}

extension HTTPResponse {
    /// A file, or the part of it the request asks for, sent from disk a chunk
    /// at a time. `etag` names this version of the file, the SHA-256 of its
    /// bytes, so a client resuming with `If-Range` gets the rest of the same
    /// file or, if it changed, the whole new one. `If-Match` naming another
    /// version is refused with 412.
    static func file(at path: String, size: Int64, etag: String, for request: HTTPRequest,
                     headers: [(name: String, value: String)] = []) -> HTTPResponse {
        let tag = "\"\(etag)\""
        let common: [(name: String, value: String)] = [("ETag", tag), ("Accept-Ranges", "bytes")] + headers
        if let match = request.header("If-Match")?.trimmingCharacters(in: .whitespaces), match != "*",
           !match.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == tag }) {
            return .json(412, ["error": ["message": "the file has changed", "type": "invalid_request_error"]],
                         headers: common)
        }
        var range = RangeRequest.parse(request.header("Range"), size: size)
        // A range is for the version the client already has part of. A
        // validator naming another, or a date, gets the whole file.
        if let ifRange = request.header("If-Range"), ifRange.trimmingCharacters(in: .whitespaces) != tag {
            range = .whole
        }
        let octets: (name: String, value: String) = ("Content-Type", "application/octet-stream")
        switch range {
        case .whole:
            return HTTPResponse(status: 200, headers: [octets] + common,
                                file: FileBody(path: path, offset: 0, length: size))
        case .part(let offset, let length):
            return HTTPResponse(status: 206,
                                headers: [octets, ("Content-Range", "bytes \(offset)-\(offset + length - 1)/\(size)")]
                                    + common,
                                file: FileBody(path: path, offset: offset, length: length))
        case .unsatisfiable:
            return .json(416, ["error": ["message": "the range starts past the end of the file",
                                         "type": "invalid_request_error"]],
                         headers: [("Content-Range", "bytes */\(size)")] + common)
        }
    }
}
