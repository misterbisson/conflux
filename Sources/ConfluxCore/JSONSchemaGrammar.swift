import Foundation

/// A chat completion's `response_format`, as a grammar for llama.cpp's
/// grammar sampler: the in-process runtime's structured output.
///
/// llama-server converts the schema with code that isn't in the llama.cpp
/// framework conflux links, so `JSONSchemaGrammar` reimplements it. Its
/// grammar is the same, so at temperature 0 both runtimes give the same
/// answer.
enum ResponseFormat {
    enum Failure: Error, Equatable {
        /// The schema is malformed: 400.
        case invalid(String)
        /// The schema asks for something this runtime doesn't enforce,
        /// though llama-server does.
        case unsupported(String)
    }

    /// The grammar for the request's response_format, or nil when it names
    /// none or asks for text. As llama-server reads it: `json_object`, or
    /// `json_schema` without a schema, means any object.
    static func grammar(for body: Data) throws(Failure) -> String? {
        // Base64 has no underscore, so images can't make this match.
        guard body.range(of: Data("response_format".utf8)) != nil else { return nil }
        guard let object = try? OrderedJSON.parse(body), let format = object["response_format"], format.isObject
        else { return nil }
        let schema: OrderedJSON?
        switch format["type"]?.string ?? "" {
        case "", "text": return nil
        case "json_object": schema = format["schema"]
        case "json_schema": schema = format["json_schema"]?["schema"]
        case let type:
            throw .invalid(#"response_format type must be one of "text", "json_object" or "json_schema", not \#(type)"#)
        }
        let anyObject = OrderedJSON.object([.init(key: "type", value: .string("object"))])
        switch schema {
        case nil, .object([])?: return try JSONSchemaGrammar.grammar(for: anyObject)
        case let schema?: return try JSONSchemaGrammar.grammar(for: schema)
        }
    }
}

/// JSON Schema to GBNF, reimplemented in Swift from llama.cpp's
/// `common/json-schema.cpp` and `common/json-schema-to-grammar.cpp` at the
/// build conflux pins (MIT licence, in App/Credits.html), so the rules it
/// writes are the same. One difference: llama.cpp turns a string's `pattern`
/// into grammar too, and this refuses it as unsupported, so the gateway can
/// try a host that runs llama-server.
struct JSONSchemaGrammar {
    typealias Failure = ResponseFormat.Failure

    static let recursionLimit = 128

    static func grammar(for schema: OrderedJSON) throws(Failure) -> String {
        var builder = Builder(root: schema)
        let node = try builder.build(schema, path: "#")
        var converter = Converter(references: builder.references.compactMapValues { $0 })
        _ = try converter.visit(node, name: "")
        // As llama.cpp writes them: sorted by name.
        return converter.rules.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            .map { "\($0) ::= \(converter.rules[$0]!)\n" }.joined()
    }

    // MARK: The schema, as llama.cpp reads it

    indirect enum Node {
        case any
        case reference(String)
        case anyOf([Node])
        case allOf([Node])
        case constant(OrderedJSON)
        case enumeration([OrderedJSON])
        case object(properties: [Property], additional: Node?)
        case tuple([Node])
        case array(items: Node, minItems: Int, maxItems: Int?)
        case string(format: Format, minLength: Int, maxLength: Int?)
        case integer(minimum: Int64, maximum: Int64)
        case number, boolean, null

        var isAny: Bool { if case .any = self { true } else { false } }
    }

    struct Property {
        var name: String
        var schema: Node
        var required: Bool
    }

    enum Format { case none, date, time, dateTime, uuid }

    /// llama.cpp's `common_chat_schema_builder`.
    struct Builder {
        let root: OrderedJSON
        /// Each `$ref`'s target, nil while it's being built.
        var references: [String: Node?] = [:]
        var depth = 0

        init(root: OrderedJSON) { self.root = root }

        static func fail(_ path: String, _ message: String) -> Failure {
            .invalid("JSON schema error at \(path): \(message)")
        }

        mutating func build(_ schema: OrderedJSON, path: String) throws(Failure) -> Node {
            depth += 1
            defer { depth -= 1 }
            guard depth <= JSONSchemaGrammar.recursionLimit else {
                throw .invalid("JSON schema is nested more than \(JSONSchemaGrammar.recursionLimit) levels deep")
            }
            guard schema.isObject else { throw Self.fail(path, "schema must be an object") }
            if let reference = schema["$ref"] { return try buildReference(reference, path: path) }
            if let key = ["oneOf", "anyOf"].first(where: { schema[$0] != nil }) {
                return .anyOf(try alternatives(schema[key]!, path: "\(path)/\(key)"))
            }

            let type = schema["type"]
            if case .array(let types)? = type {
                guard !types.isEmpty else { throw Self.fail(path, "type must not be empty") }
                var children: [Node] = []
                for (index, each) in types.enumerated() {
                    children.append(try build(schema.replacing("type", with: each), path: "\(path)/type/\(index)"))
                }
                return .anyOf(children)
            }
            if let constant = schema["const"] { return .constant(constant) }
            if let values = schema["enum"] {
                guard case .array(let values) = values, !values.isEmpty else {
                    throw Self.fail(path, "enum must be a non-empty array")
                }
                return .enumeration(values)
            }
            let typeName: String
            switch type {
            case nil, .null?: typeName = ""
            case .string(let name)?: typeName = name
            default: throw Self.fail(path, "type must be a string or an array of strings")
            }
            let hasProperties = schema["properties"] != nil
                || (schema["additionalProperties"] != nil && schema["additionalProperties"] != .bool(true))

            switch typeName {
            case "":
                // Without a type, the structural keywords decide.
                if hasProperties { return try object(schema, path: path) }
                if let all = schema["allOf"] { return .allOf(try alternatives(all, path: "\(path)/allOf")) }
                if schema["items"] != nil || schema["prefixItems"] != nil { return try array(schema, path: path) }
                let format = try Self.format(schema, path: path)
                if schema["pattern"] != nil || schema["minLength"] != nil || schema["maxLength"] != nil || format != .none {
                    return try string(schema, path: path)
                }
                return .any
            case "object":
                if !hasProperties, let all = schema["allOf"] {
                    return .allOf(try alternatives(all, path: "\(path)/allOf"))
                }
                return try object(schema, path: path)
            case "string":
                if let all = schema["allOf"] { return .allOf(try alternatives(all, path: "\(path)/allOf")) }
                return try string(schema, path: path)
            case "array": return try array(schema, path: path)
            case "integer": return try integer(schema, path: path)
            case "number": return .number
            case "boolean": return .boolean
            case "null": return .null
            default: throw Self.fail(path, "unrecognized type \(typeName)")
            }
        }

        mutating func buildReference(_ value: OrderedJSON, path: String) throws(Failure) -> Node {
            guard let reference = value.string else { throw Self.fail(path, "$ref must be a string") }
            guard reference.hasPrefix("#/") else {
                throw .unsupported("JSON schema error at \(path): unsupported $ref \(reference), only references into the same document are supported")
            }
            if references[reference] == nil {
                // Reserved first, so a cycle back to it stops here.
                references[reference] = .some(nil)
                references[reference] = .some(try build(try resolve(reference, path: path), path: reference))
            }
            return .reference(reference)
        }

        func resolve(_ reference: String, path: String) throws(Failure) -> OrderedJSON {
            var target = root
            for selector in reference.dropFirst().split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
                let selector = String(selector)
                if target.isObject, let next = target[selector] {
                    target = next
                } else if case .array(let items) = target {
                    guard let index = Int(selector), index >= 0, index < items.count else {
                        throw Self.fail(path, "cannot resolve $ref \(reference), \(selector) is out of range")
                    }
                    target = items[index]
                } else {
                    throw Self.fail(path, "cannot resolve $ref \(reference), \(selector) not found")
                }
            }
            return target
        }

        mutating func alternatives(_ value: OrderedJSON, path: String) throws(Failure) -> [Node] {
            guard case .array(let options) = value else { throw Self.fail(path, "must be an array of schemas") }
            guard !options.isEmpty else { throw Self.fail(path, "must not be empty") }
            var children: [Node] = []
            for (index, option) in options.enumerated() {
                children.append(try build(option, path: "\(path)/\(index)"))
            }
            return children
        }

        mutating func object(_ schema: OrderedJSON, path: String) throws(Failure) -> Node {
            var required: Set<String> = []
            if case .array(let names)? = schema["required"] {
                for case .string(let name) in names { required.insert(name) }
            }
            var properties: [Property] = []
            if let list = schema["properties"] {
                guard case .object(let members) = list else { throw Self.fail(path, "properties must be an object") }
                for member in members {
                    properties.append(Property(name: member.key,
                                               schema: try build(member.value, path: "\(path)/properties/\(member.key)"),
                                               required: required.contains(member.key)))
                }
            }
            var additional: Node?
            switch schema["additionalProperties"] {
            case .bool(let allowed)?: additional = allowed ? .any : nil
            case let other? where other.isObject:
                additional = try build(other, path: "\(path)/additionalProperties")
            case .some: throw Self.fail(path, "additionalProperties must be a boolean or a schema")
            case nil: additional = schema["properties"] == nil ? .any : nil
            }
            return .object(properties: properties, additional: additional)
        }

        mutating func array(_ schema: OrderedJSON, path: String) throws(Failure) -> Node {
            var items = Node.any
            // items wins when both are there; an array of schemas is a tuple.
            if let key = ["items", "prefixItems"].first(where: { schema[$0] != nil }) {
                if case .array(let list) = schema[key]! {
                    var tuple: [Node] = []
                    for (index, item) in list.enumerated() {
                        tuple.append(try build(item, path: "\(path)/\(key)/\(index)"))
                    }
                    return .tuple(tuple)
                }
                items = try build(schema[key]!, path: "\(path)/\(key)")
            }
            return .array(items: items, minItems: try Self.count(schema, "minItems", path: path) ?? 0,
                          maxItems: try Self.count(schema, "maxItems", path: path))
        }

        mutating func string(_ schema: OrderedJSON, path: String) throws(Failure) -> Node {
            if let pattern = schema["pattern"] {
                guard pattern.string != nil else { throw Self.fail(path, "pattern must be a string") }
                throw .unsupported("this host doesn't enforce pattern in a response_format schema")
            }
            return .string(format: try Self.format(schema, path: path),
                           minLength: try Self.count(schema, "minLength", path: path) ?? 0,
                           maxLength: try Self.count(schema, "maxLength", path: path))
        }

        func integer(_ schema: OrderedJSON, path: String) throws(Failure) -> Node {
            var minimum = Int64.min, maximum = Int64.max
            if schema["minimum"] != nil {
                minimum = try Self.bound(schema, "minimum", path: path, roundUp: true)
            } else if schema["exclusiveMinimum"] != nil {
                minimum = try Self.bound(schema, "exclusiveMinimum", path: path, roundUp: false) &+ 1
            }
            if schema["maximum"] != nil {
                maximum = try Self.bound(schema, "maximum", path: path, roundUp: false)
            } else if schema["exclusiveMaximum"] != nil {
                maximum = try Self.bound(schema, "exclusiveMaximum", path: path, roundUp: true) &- 1
            }
            return .integer(minimum: minimum, maximum: maximum)
        }

        static func count(_ schema: OrderedJSON, _ key: String, path: String) throws(Failure) -> Int? {
            guard let value = schema[key] else { return nil }
            guard let integer = value.integer, integer >= 0, integer <= Int64(Int32.max) else {
                throw fail(path, "\(key) must be a non-negative integer")
            }
            return Int(integer)
        }

        /// A fractional bound is rounded inwards, towards the integers it
        /// still admits.
        static func bound(_ schema: OrderedJSON, _ key: String, path: String, roundUp: Bool) throws(Failure) -> Int64 {
            let value = schema[key]!
            if let integer = value.integer { return integer }
            guard let number = value.number else { throw fail(path, "\(key) must be a number") }
            let rounded = roundUp ? number.rounded(.up) : number.rounded(.down)
            if rounded >= 9.2e18 { return .max }
            if rounded <= -9.2e18 { return .min }
            return Int64(rounded)
        }

        static func format(_ schema: OrderedJSON, path: String) throws(Failure) -> Format {
            guard let value = schema["format"] else { return .none }
            guard let format = value.string else { throw fail(path, "format must be a string") }
            switch format {
            case "date": return .date
            case "time": return .time
            case "date-time": return .dateTime
            case "uuid", "uuid1", "uuid2", "uuid3", "uuid4", "uuid5": return .uuid
            default: return .none
            }
        }
    }

    // MARK: Writing the grammar

    struct Builtin {
        let content: String
        let uses: [String]
    }

    static let space = #"| " " | "\n"{1,2} [ \t]{0,20}"#

    static let primitives: [String: Builtin] = [
        "boolean": Builtin(content: #"("true" | "false")"#, uses: []),
        "decimal-part": Builtin(content: "[0-9]{1,16}", uses: []),
        "integral-part": Builtin(content: "[0] | [1-9] [0-9]{0,15}", uses: []),
        "number": Builtin(content: #"("-"? integral-part) ("." decimal-part)? ([eE] [-+]? integral-part)?"#,
                          uses: ["integral-part", "decimal-part"]),
        "integer": Builtin(content: #"("-"? integral-part)"#, uses: ["integral-part"]),
        "value": Builtin(content: "object | array | string | number | boolean | null",
                         uses: ["object", "array", "string", "number", "boolean", "null"]),
        "object": Builtin(content: #""{" space ( string ":" space value ("," space string ":" space value)* )? space "}""#,
                          uses: ["string", "value"]),
        "array": Builtin(content: #""[" space ( value ("," space value)* )? space "]""#, uses: ["value"]),
        "uuid": Builtin(content: #""\"" [0-9a-fA-F]{8} "-" [0-9a-fA-F]{4} "-" [0-9a-fA-F]{4} "-" [0-9a-fA-F]{4} "-" [0-9a-fA-F]{12} "\"""#,
                        uses: []),
        "char": Builtin(content: #"[^"\\\x7F\x00-\x1F] | [\\] (["\\bfnrt] | "u" [0-9a-fA-F]{4})"#, uses: []),
        "string": Builtin(content: #""\"" char* "\"""#, uses: ["char"]),
        "null": Builtin(content: #""null""#, uses: []),
    ]

    static let formats: [String: Builtin] = [
        "date": Builtin(content: #"[0-9]{4} "-" ( "0" [1-9] | "1" [0-2] ) "-" ( "0" [1-9] | [1-2] [0-9] | "3" [0-1] )"#,
                        uses: []),
        "time": Builtin(content: #"([01] [0-9] | "2" [0-3]) ":" [0-5] [0-9] ":" [0-5] [0-9] ( "." [0-9]{3} )? ( "Z" | ( "+" | "-" ) ( [01] [0-9] | "2" [0-3] ) ":" [0-5] [0-9] )"#,
                        uses: []),
        "date-time": Builtin(content: #"date "T" time"#, uses: ["date", "time"]),
        "date-string": Builtin(content: #""\"" date "\"""#, uses: ["date"]),
        "time-string": Builtin(content: #""\"" time "\"""#, uses: ["time"]),
        "date-time-string": Builtin(content: #""\"" date-time "\"""#, uses: ["date-time"]),
    ]

    static let reserved: Set<String> = Set(["root"]).union(primitives.keys).union(formats.keys)

    /// llama.cpp's `common_chat_schema_converter`.
    struct Converter {
        var rules: [String: String] = ["space": JSONSchemaGrammar.space]
        let references: [String: Node]
        var resolving: Set<String> = []
        var depth = 0

        init(references: [String: Node]) { self.references = references }

        mutating func addRule(_ name: String, _ rule: String) -> String {
            let escaped = JSONSchemaGrammar.ruleName(name)
            if rules[escaped] == nil || rules[escaped] == rule {
                rules[escaped] = rule
                return escaped
            }
            var index = 0
            while let existing = rules[escaped + String(index)], existing != rule { index += 1 }
            rules[escaped + String(index)] = rule
            return escaped + String(index)
        }

        mutating func addPrimitive(_ name: String, _ builtin: Builtin) -> String {
            let added = addRule(name, builtin.content)
            for use in builtin.uses where rules[use] == nil {
                if let rule = JSONSchemaGrammar.primitives[use] ?? JSONSchemaGrammar.formats[use] {
                    _ = addPrimitive(use, rule)
                }
            }
            return added
        }

        mutating func primitive(_ ruleName: String, _ type: String) -> String {
            addPrimitive(ruleName == "root" ? "root" : type, JSONSchemaGrammar.primitives[type]!)
        }

        mutating func visit(_ node: Node, name: String) throws(Failure) -> String {
            depth += 1
            defer { depth -= 1 }
            guard depth <= JSONSchemaGrammar.recursionLimit else {
                throw .invalid("JSON schema is nested more than \(JSONSchemaGrammar.recursionLimit) levels deep")
            }
            let ruleName = JSONSchemaGrammar.reserved.contains(name) ? name + "-" : name.isEmpty ? "root" : name
            let subName = name + (name.isEmpty ? "" : "-")

            switch node {
            case .reference(let reference):
                return addRule(ruleName, try resolve(reference))
            case .anyOf(let alternatives):
                var names: [String] = []
                for (index, alternative) in alternatives.enumerated() {
                    names.append(try visit(alternative, name: name + (name.isEmpty ? "alternative-" : "-") + String(index)))
                }
                return addRule(ruleName, names.joined(separator: " | "))
            case .allOf(let children):
                return try allOf(children, name: name, ruleName: ruleName)
            case .constant(let value):
                return addRule(ruleName, JSONSchemaGrammar.literal(value.dumped))
            case .enumeration(let values):
                return addRule(ruleName, "(" + values.map { JSONSchemaGrammar.literal($0.dumped) }.joined(separator: " | ") + ")")
            case .object(let properties, let additional):
                if properties.isEmpty, additional?.isAny == true {
                    return addRule(ruleName, addPrimitive("object", JSONSchemaGrammar.primitives["object"]!))
                }
                return addRule(ruleName, try objectRule(properties.map { ($0.name, $0.schema) },
                                                        required: Set(properties.filter(\.required).map(\.name)),
                                                        name: name, additional: additional))
            case .tuple(let items):
                var rule = #""[" space "#
                for (index, item) in items.enumerated() {
                    if index > 0 { rule += #" "," space "# }
                    rule += try visit(item, name: subName + "tuple-" + String(index))
                }
                return addRule(ruleName, rule + #" space "]""#)
            case .array(let items, let minimum, let maximum):
                if items.isAny, minimum == 0, maximum == nil { return primitive(ruleName, "array") }
                let item = try visit(items, name: subName + "item")
                return addRule(ruleName, #""[" space "# + JSONSchemaGrammar.repetition(item, minimum, maximum ?? Int.max,
                                                                                         separator: #""," space"#)
                                         + #" space "]""#)
            case .string(let format, let minimum, let maximum):
                switch format {
                case .uuid: return primitive(ruleName, "uuid")
                case .date, .time, .dateTime:
                    let name = (format == .date ? "date" : format == .time ? "time" : "date-time") + "-string"
                    return addRule(ruleName, addPrimitive(name, JSONSchemaGrammar.formats[name]!))
                case .none:
                    guard minimum > 0 || maximum != nil else { return primitive(ruleName, "string") }
                    let char = addPrimitive("char", JSONSchemaGrammar.primitives["char"]!)
                    return addRule(ruleName, #""\"" "# + JSONSchemaGrammar.repetition(char, minimum, maximum ?? Int.max)
                                             + #" "\"""#)
                }
            case .integer(let minimum, let maximum):
                if minimum == .min && maximum == .max { return primitive(ruleName, "integer") }
                var out = ""
                IntegerRange.write(minimum, maximum, into: &out)
                return addRule(ruleName, "(" + out + ")")
            case .number: return primitive(ruleName, "number")
            case .boolean: return primitive(ruleName, "boolean")
            case .null: return primitive(ruleName, "null")
            case .any: return addRule(ruleName, addPrimitive("value", JSONSchemaGrammar.primitives["value"]!))
            }
        }

        mutating func resolve(_ reference: String) throws(Failure) -> String {
            let fragment = reference.firstIndex(of: "#").map { String(reference[reference.index(after: $0)...]) } ?? reference
            var name = "ref" + JSONSchemaGrammar.ruleName(fragment)
            if rules[name] == nil && !resolving.contains(reference) {
                guard let target = references[reference] else { throw .invalid("Unresolved $ref \(reference)") }
                resolving.insert(reference)
                name = try visit(target, name: name)
                resolving.remove(reference)
            }
            return name
        }

        mutating func allOf(_ children: [Node], name: String, ruleName: String) throws(Failure) -> String {
            var required: Set<String> = []
            var properties: [(name: String, schema: Node)] = []
            var enumCounts: [String: Int] = [:]
            func add(_ component: Node, required isRequired: Bool, depth: Int) throws(Failure) {
                guard depth < JSONSchemaGrammar.recursionLimit else {
                    throw .invalid("JSON schema is nested more than \(JSONSchemaGrammar.recursionLimit) levels deep")
                }
                switch component {
                case .reference(let reference):
                    if let target = references[reference] { try add(target, required: isRequired, depth: depth + 1) }
                case .object(let members, _):
                    for member in members {
                        properties.append((member.name, member.schema))
                        if isRequired { required.insert(member.name) }
                    }
                case .enumeration(let values):
                    for value in values { enumCounts[JSONSchemaGrammar.literal(value.dumped), default: 0] += 1 }
                default:
                    break
                }
            }
            for child in children {
                if case .anyOf(let alternatives) = child {
                    for alternative in alternatives { try add(alternative, required: false, depth: 0) }
                } else {
                    try add(child, required: true, depth: 0)
                }
            }
            let shared = enumCounts.filter { $0.value == children.count }.keys
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            if !shared.isEmpty {
                return addRule(ruleName, "(" + shared.joined(separator: " | ") + ")")
            }
            return addRule(ruleName, try objectRule(properties, required: required, name: name, additional: nil))
        }

        mutating func objectRule(_ properties: [(name: String, schema: Node)], required: Set<String>, name: String,
                                 additional: Node?) throws(Failure) -> String {
            let prefix = name + (name.isEmpty ? "" : "-")
            var requiredNames: [String] = [], optionalNames: [String] = [], allNames: [String] = []
            var entries: [String: String] = [:]
            for property in properties {
                let value = try visit(property.schema, name: prefix + property.name)
                entries[property.name] = addRule(prefix + property.name + "-kv",
                                                 JSONSchemaGrammar.literal(OrderedJSON.quoted(property.name))
                                                 + #" space ":" space "# + value)
                if required.contains(property.name) {
                    requiredNames.append(property.name)
                } else {
                    optionalNames.append(property.name)
                }
                allNames.append(property.name)
            }
            if let additional {
                let subName = prefix + "additional"
                let value = additional.isAny
                    ? addPrimitive("value", JSONSchemaGrammar.primitives["value"]!)
                    : try visit(additional, name: subName + "-value")
                let key = allNames.isEmpty
                    ? addPrimitive("string", JSONSchemaGrammar.primitives["string"]!)
                    : addRule(subName + "-k", try notStrings(allNames))
                entries["*"] = addRule(subName + "-kv", key + #" ":" space "# + value)
                optionalNames.append("*")
            }
            if requiredNames.isEmpty && optionalNames.isEmpty { return #""{" space "}""# }

            var rule = #""{" space "#
            rule += requiredNames.map { entries[$0]! }.joined(separator: #" "," space "#)
            if !optionalNames.isEmpty {
                rule += " ("
                if !requiredNames.isEmpty { rule += #" "," space ( "# }
                func chain(_ keys: ArraySlice<String>, firstOptional: Bool) -> String {
                    guard let key = keys.first else { return "" }
                    let entry = entries[key]!
                    let following = #"( "," space "# + entry + " )"
                    var result = firstOptional
                        ? following + (key == "*" ? "*" : "?")
                        : entry + (key == "*" ? " " + following + "*" : "")
                    if keys.count > 1 {
                        result += " " + addRule(prefix + key + "-rest", chain(keys.dropFirst(), firstOptional: true))
                    }
                    return result
                }
                rule += optionalNames.indices.map { chain(optionalNames[$0...], firstOptional: false) }
                    .joined(separator: " | ")
                if !requiredNames.isEmpty { rule += " )" }
                rule += " )?"
            }
            return rule + #" space "}""#
        }

        /// A JSON string that is none of `strings`, by a trie of their
        /// characters.
        mutating func notStrings(_ strings: [String]) throws(Failure) -> String {
            struct TrieNode {
                var children: [UInt32: Int] = [:]
                var ends = false
            }
            var nodes = [TrieNode()]
            for string in strings {
                var current = 0
                for scalar in string.unicodeScalars {
                    if let next = nodes[current].children[scalar.value] {
                        current = next
                    } else {
                        nodes.append(TrieNode())
                        nodes[current].children[scalar.value] = nodes.count - 1
                        current = nodes.count - 1
                    }
                }
                nodes[current].ends = true
            }
            let char = addPrimitive("char", JSONSchemaGrammar.primitives["char"]!)
            var out = #"["] ( "#
            func walk(_ index: Int, depth: Int) throws(Failure) {
                guard depth < JSONSchemaGrammar.recursionLimit else {
                    throw .invalid("JSON schema property name is longer than \(JSONSchemaGrammar.recursionLimit) chars")
                }
                var rejects = ""
                for (offset, (scalar, child)) in nodes[index].children.sorted(by: { $0.key < $1.key }).enumerated() {
                    let character = String(Unicode.Scalar(scalar)!)
                    rejects += character
                    if offset > 0 { out += " | " }
                    out += "[" + character + "]"
                    if nodes[child].children.isEmpty {
                        out += " " + char + "+"
                    } else {
                        out += " ("
                        try walk(child, depth: depth + 1)
                        out += ")"
                    }
                }
                if !nodes[index].children.isEmpty { out += #" | [^""# + rejects + "] " + char + "*" }
            }
            try walk(0, depth: 0)
            out += " )"
            if !nodes[0].ends { out += "?" }
            return out + #" ["]"#
        }
    }

    // MARK: Helpers

    /// Letters, digits and hyphens, with each run of anything else made one
    /// hyphen.
    static func ruleName(_ name: String) -> String {
        var out = "", invalid = false
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
                invalid = false
            default:
                if !invalid { out += "-" }
                invalid = true
            }
        }
        return out
    }

    /// `text` as a GBNF literal.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r": out += #"\r"#
            case "\n": out += #"\n"#
            case "\"": out += #"\""#
            case "\\": out += #"\\"#
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `item` from `minimum` to `maximum` times (`Int.max` for no limit),
    /// with `separator` between them.
    static func repetition(_ item: String, _ minimum: Int, _ maximum: Int, separator: String = "") -> String {
        let hasMaximum = maximum != Int.max
        if maximum == 0 { return "" }
        if minimum == 0 && maximum == 1 { return item + "?" }
        if separator.isEmpty {
            if minimum == 1 && !hasMaximum { return item + "+" }
            if minimum == 0 && !hasMaximum { return item + "*" }
            return item + "{" + String(minimum) + "," + (hasMaximum ? String(maximum) : "") + "}"
        }
        var result = item + " " + repetition("(" + separator + " " + item + ")", minimum == 0 ? 0 : minimum - 1,
                                             hasMaximum ? maximum - 1 : maximum)
        if minimum == 0 { result = "(" + result + ")?" }
        return result
    }
}

/// An integer between two bounds as GBNF, digit by digit: llama.cpp's
/// `build_min_max_int`. `Int64.min` and `Int64.max` stand for no bound.
enum IntegerRange {
    static func write(_ minimum: Int64, _ maximum: Int64, into out: inout String, decimalsLeft: Int = 16,
                      topLevel: Bool = true) {
        var minimum = minimum
        let hasMinimum = minimum != .min, hasMaximum = maximum != .max

        func character(_ byte: UInt8) -> String { String(Unicode.Scalar(byte)) }
        func digitRange(_ from: UInt8, _ to: UInt8) {
            out += "[" + character(from) + (from == to ? "" : "-" + character(to)) + "]"
        }
        func moreDigits(_ minimum: Int, _ maximum: Int) {
            out += "[0-9]"
            if minimum == maximum && minimum == 1 { return }
            out += "{\(minimum)"
            if maximum != minimum {
                out += ","
                if maximum != Int.max { out += String(maximum) }
            }
            out += "}"
        }
        func repeated(_ digit: Character, _ count: Int) -> [UInt8] { Array(String(repeating: digit, count: count).utf8) }
        func uniformRange(_ from: [UInt8], _ to: [UInt8]) {
            var i = 0
            while i < from.count && i < to.count && from[i] == to[i] { i += 1 }
            if i > 0 { out += "\"" + String(decoding: from[0..<i], as: UTF8.self) + "\"" }
            guard i < from.count && i < to.count else { return }
            if i > 0 { out += " " }
            let length = from.count - i - 1
            guard length > 0 else {
                out += "[" + character(from[i]) + "-" + character(to[i]) + "]"
                return
            }
            let fromRest = Array(from[(i + 1)...]), toRest = Array(to[(i + 1)...])
            let zeros = repeated("0", length), nines = repeated("9", length)
            var reached = false
            out += "("
            if fromRest == zeros {
                digitRange(from[i], to[i] &- 1)
                out += " "
                moreDigits(length, length)
            } else {
                out += "[" + character(from[i]) + "] ("
                uniformRange(fromRest, nines)
                out += ")"
                if from[i] < to[i] &- 1 {
                    out += " | "
                    if toRest == nines {
                        digitRange(from[i] + 1, to[i])
                        reached = true
                    } else {
                        digitRange(from[i] + 1, to[i] &- 1)
                    }
                    out += " "
                    moreDigits(length, length)
                }
            }
            if !reached {
                out += " | "
                digitRange(to[i], to[i])
                out += " "
                uniformRange(zeros, toRest)
            }
            out += ")"
        }

        if hasMinimum && hasMaximum {
            if minimum < 0 && maximum < 0 {
                out += #""-" ("#
                write(0 &- maximum, 0 &- minimum, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
                out += ")"
                return
            }
            if minimum < 0 {
                out += #""-" ("#
                write(0, 0 &- minimum, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
                out += ") | "
                minimum = 0
            }
            var low = Array(String(minimum).utf8)
            let high = Array(String(maximum).utf8)
            if low.count < high.count {
                for digits in low.count..<high.count {
                    uniformRange(low, repeated("9", digits))
                    low = Array(("1" + String(repeating: "0", count: digits)).utf8)
                    out += " | "
                }
            }
            uniformRange(low, high)
            return
        }

        let lessDecimals = max(decimalsLeft - 1, 1)
        if hasMinimum {
            if minimum < 0 {
                out += #""-" ("#
                write(.min, 0 &- minimum, into: &out, decimalsLeft: decimalsLeft, topLevel: false)
                out += ") | [0] | [1-9] "
                moreDigits(0, decimalsLeft - 1)
            } else if minimum == 0 {
                if topLevel {
                    out += "[0] | [1-9] "
                    moreDigits(0, lessDecimals)
                } else {
                    moreDigits(1, decimalsLeft)
                }
            } else if minimum <= 9 {
                let digit = UInt8(ascii: "0") + UInt8(minimum)
                let start = topLevel ? UInt8(ascii: "1") : UInt8(ascii: "0")
                if digit > start {
                    digitRange(start, digit - 1)
                    out += " "
                    moreDigits(1, lessDecimals)
                    out += " | "
                }
                digitRange(digit, UInt8(ascii: "9"))
                out += " "
                moreDigits(0, lessDecimals)
            } else {
                let text = Array(String(minimum).utf8)
                let first = text[0]
                if first > UInt8(ascii: "1") {
                    digitRange(topLevel ? UInt8(ascii: "1") : UInt8(ascii: "0"), first - 1)
                    out += " "
                    moreDigits(text.count, lessDecimals)
                    out += " | "
                }
                digitRange(first, first)
                out += " ("
                write(Int64(String(decoding: text.dropFirst(), as: UTF8.self))!, .max, into: &out,
                      decimalsLeft: lessDecimals, topLevel: false)
                out += ")"
                if first < UInt8(ascii: "9") {
                    out += " | "
                    digitRange(first + 1, UInt8(ascii: "9"))
                    out += " "
                    moreDigits(text.count - 1, lessDecimals)
                }
            }
            return
        }
        if hasMaximum {
            if maximum >= 0 {
                if topLevel {
                    out += #""-" [1-9] "#
                    moreDigits(0, lessDecimals)
                    out += " | "
                }
                write(0, maximum, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
            } else {
                out += #""-" ("#
                write(0 &- maximum, .max, into: &out, decimalsLeft: decimalsLeft, topLevel: false)
                out += ")"
            }
        }
    }
}
