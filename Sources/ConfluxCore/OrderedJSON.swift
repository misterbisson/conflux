import Foundation

/// JSON that keeps the order of each object's keys, which JSONSerialization
/// doesn't. A response_format schema lists properties in the order the
/// answer should give them, and a model writes the earlier ones first.
indirect enum OrderedJSON: Equatable {
    struct Member: Equatable {
        var key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// As written, so a constant is matched exactly.
    case number(String)
    case bool(Bool)
    case null

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// A number written without a fraction or exponent, as llama.cpp's JSON
    /// library reads one.
    var integer: Int64? {
        guard case .number(let text) = self, !text.contains(where: { ".eE".contains($0) }) else { return nil }
        return Int64(text)
    }

    var number: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    /// The same object with `key` set to `value`, in its place.
    func replacing(_ key: String, with value: OrderedJSON) -> OrderedJSON {
        guard case .object(var members) = self else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key: key, value: value))
        }
        return .object(members)
    }

    /// Compact JSON, keys in their order, as llama.cpp's JSON library
    /// writes it: integers as they are, other numbers in their shortest
    /// form, such as 2.5 for 2.50.
    var dumped: String {
        switch self {
        case .object(let members):
            "{" + members.map { "\(Self.quoted($0.key)):\($0.value.dumped)" }.joined(separator: ",") + "}"
        case .array(let values): "[" + values.map(\.dumped).joined(separator: ",") + "]"
        case .string(let value): Self.quoted(value)
        case .number(let text):
            if let integer { String(integer) } else if let number { number.description } else { text }
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        }
    }

    /// A JSON string literal, escaped as llama.cpp's JSON library does.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += #"\""#
            case "\\": result += #"\\"#
            case "\u{08}": result += #"\b"#
            case "\u{0C}": result += #"\f"#
            case "\n": result += #"\n"#
            case "\r": result += #"\r"#
            case "\t": result += #"\t"#
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    struct Malformed: Error {}

    static func parse(_ data: Data) throws(Malformed) -> OrderedJSON {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        guard reader.index == reader.bytes.count else { throw Malformed() }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        /// Deeper than any schema needs, and shallow enough for the stack.
        static let maxDepth = 128

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws(Malformed) {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw Malformed() }
                index += 1
            }
        }

        mutating func value(depth: Int) throws(Malformed) -> OrderedJSON {
            guard depth < Self.maxDepth else { throw Malformed() }
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    members.append(Member(key: key, value: try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "}") { return .object(members) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { throw Malformed() }
                }
            case UInt8(ascii: "["):
                index += 1
                var values: [OrderedJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(values)
                }
                while true {
                    values.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw Malformed() }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "]") { return .array(values) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { throw Malformed() }
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default:
                return .number(try number())
            }
        }

        mutating func number() throws(Malformed) -> String {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw Malformed() }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw Malformed() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                guard digits() > 0 else { throw Malformed() }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws(Malformed) -> String {
            try expect("\"")
            var result: [UInt8] = []
            while true {
                guard index < bytes.count else { throw Malformed() }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: result, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw Malformed() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): result.append(escape)
                    case UInt8(ascii: "b"): result.append(0x08)
                    case UInt8(ascii: "f"): result.append(0x0C)
                    case UInt8(ascii: "n"): result.append(0x0A)
                    case UInt8(ascii: "r"): result.append(0x0D)
                    case UInt8(ascii: "t"): result.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex()
                        if (0xD800..<0xDC00).contains(scalar) {
                            try expect("\\u")
                            let low = try hex()
                            guard (0xDC00..<0xE000).contains(low) else { throw Malformed() }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw Malformed() }
                        result += Array(String(Character(unicode)).utf8)
                    default:
                        throw Malformed()
                    }
                case 0..<0x20:
                    throw Malformed()
                default:
                    result.append(byte)
                }
            }
        }

        mutating func hex() throws(Malformed) -> UInt32 {
            guard index + 4 <= bytes.count, bytes[index..<(index + 4)].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
                  let value = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16)
            else { throw Malformed() }
            index += 4
            return value
        }
    }
}
