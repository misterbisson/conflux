import Foundation

/// A chat completion's `response_format` schema, as Apple's guided
/// generation takes it: the shapes `DynamicGenerationSchema` can build.
///
/// Read with the same parser as the in-process llama.cpp runtime
/// (`JSONSchemaGrammar.Builder`), so a schema that's malformed for one is
/// malformed for both. What Apple's model can't enforce, but a llama.cpp
/// host can, is `unsuited`, so the gateway tries another host: a string's
/// `pattern`, `minLength`, `maxLength` or `format`, `allOf`, tuples, objects
/// whose properties aren't listed, and schemas that refer to themselves.
/// A number's bounds are left to the model, as llama.cpp leaves them.
///
/// Kept apart from the Foundation Models types, so it can be tested on a
/// machine without Apple Intelligence.
indirect enum AppleModelSchema: Equatable, Sendable {
    case object(name: String, properties: [Property])
    /// One of several schemas: `anyOf`, `oneOf`, a list of types or an
    /// `enum` of mixed values.
    case choice(name: String, [AppleModelSchema])
    /// An `enum` of strings.
    case strings(name: String, [String])
    /// A string `const`.
    case constant(String)
    case array(AppleModelSchema, minimum: Int?, maximum: Int?)
    case string
    case integer(minimum: Int?, maximum: Int?)
    case number
    case boolean
    case null

    struct Property: Equatable, Sendable {
        var name: String
        var description: String?
        var schema: AppleModelSchema
        var optional: Bool
    }

    typealias Failure = AppleModelRequest.Failure

    /// Large enough for any schema a client writes, small enough that
    /// references used many times over can't expand without end.
    static let sizeLimit = 2000

    /// The request's schema, or nil when it asks for text.
    static func parse(_ body: Data) throws(Failure) -> AppleModelSchema? {
        // Base64 has no underscore, so images can't make this match.
        guard body.range(of: Data("response_format".utf8)) != nil else { return nil }
        guard let object = try? OrderedJSON.parse(body), let format = object["response_format"], format.isObject
        else { return nil }
        let schema: OrderedJSON?
        var name = "Answer"
        switch format["type"]?.string ?? "" {
        case "", "text": return nil
        case "json_object": schema = format["schema"]
        case "json_schema":
            schema = format["json_schema"]?["schema"]
            if let given = format["json_schema"]?["name"]?.string, !given.isEmpty { name = given }
        case let type:
            throw .invalid(#"response_format type must be one of "text", "json_object" or "json_schema", not \#(type)"#)
        }
        guard let schema, schema != .object([]) else {
            throw .unsuited("Apple's model here doesn't take a schema that allows any JSON object")
        }
        var builder = JSONSchemaGrammar.Builder(root: schema)
        let node: JSONSchemaGrammar.Node
        do {
            node = try builder.build(schema, path: "#")
        } catch {
            switch error {
            case .invalid(let message): throw .invalid(message)
            case .unsupported(let message): throw .unsuited(message)
            }
        }
        var converter = Converter(references: builder.references.compactMapValues { $0 })
        return try converter.convert(node, name: name)
    }

    /// The parser's nodes, as Apple's shapes.
    struct Converter {
        let references: [String: JSONSchemaGrammar.Node]
        /// References being expanded, to find one that refers to itself.
        var expanding: Set<String> = []
        /// Names given so far: Apple's model needs each to be unique.
        var names: Set<String> = []
        var size = 0

        static func unsuited(_ what: String) -> Failure {
            .unsuited("Apple's model here doesn't enforce \(what) in a response_format schema")
        }

        mutating func unique(_ name: String) -> String {
            var candidate = name
            var count = 1
            while names.contains(candidate) {
                count += 1
                candidate = "\(name)\(count)"
            }
            names.insert(candidate)
            return candidate
        }

        mutating func convert(_ node: JSONSchemaGrammar.Node, name: String) throws(Failure) -> AppleModelSchema {
            size += 1
            guard size <= AppleModelSchema.sizeLimit else { throw Self.unsuited("a schema this large") }
            switch node {
            case .any:
                throw Self.unsuited("a value of any type")
            case .reference(let reference):
                guard !expanding.contains(reference), let target = references[reference] else {
                    throw Self.unsuited("a schema that refers to itself")
                }
                expanding.insert(reference)
                defer { expanding.remove(reference) }
                return try convert(target, name: name)
            case .anyOf(let children):
                let name = unique(name)
                var choices: [AppleModelSchema] = []
                for (index, child) in children.enumerated() {
                    choices.append(try convert(child, name: "\(name).\(index + 1)"))
                }
                return .choice(name: name, choices)
            case .allOf:
                throw Self.unsuited("allOf")
            case .constant(let value):
                return try constant(value)
            case .enumeration(let values):
                let strings = values.compactMap(\.string)
                if strings.count == values.count { return .strings(name: unique(name), strings) }
                var choices: [AppleModelSchema] = []
                for value in values { choices.append(try constant(value)) }
                return .choice(name: unique(name), choices)
            case .object(let properties, let additional):
                if additional != nil, properties.isEmpty { throw Self.unsuited("an object whose properties aren't listed") }
                // With properties listed, an answer that gives only those
                // matches, whatever else additionalProperties allows.
                let name = unique(name)
                var converted: [Property] = []
                for property in properties {
                    converted.append(Property(name: property.name, description: property.description,
                                              schema: try convert(property.schema, name: "\(name).\(property.name)"),
                                              optional: !property.required))
                }
                return .object(name: name, properties: converted)
            case .tuple:
                throw Self.unsuited("an array of differently typed items")
            case .array(let items, let minItems, let maxItems):
                return .array(try convert(items, name: "\(name).item"), minimum: minItems > 0 ? minItems : nil,
                              maximum: maxItems)
            case .string(let format, let minLength, let maxLength):
                if format != .none { throw Self.unsuited("a string's format") }
                if minLength > 0 || maxLength != nil { throw Self.unsuited("a string's length") }
                return .string
            case .integer(let minimum, let maximum):
                return .integer(minimum: minimum == .min ? nil : Int(minimum), maximum: maximum == .max ? nil : Int(maximum))
            case .number: return .number
            case .boolean: return .boolean
            case .null: return .null
            }
        }

        func constant(_ value: OrderedJSON) throws(Failure) -> AppleModelSchema {
            switch value {
            case .string(let string): return .constant(string)
            case .null: return .null
            case .number:
                guard let integer = value.integer, let exact = Int(exactly: integer) else {
                    throw Self.unsuited("a constant that isn't a string, an integer or null")
                }
                return .integer(minimum: exact, maximum: exact)
            default:
                throw Self.unsuited("a constant that isn't a string, an integer or null")
            }
        }
    }
}
