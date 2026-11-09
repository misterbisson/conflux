import Foundation
import Testing
@testable import ConfluxCore

/// The in-process runtime's structured output: response_format as a grammar
/// (docs/clients.md), written as llama.cpp's own converter writes it. The
/// grammars are checked against llama.cpp itself in
/// `LlamaHostIntegrationTests`.
@Suite struct StructuredOutputTests {
    func grammar(_ format: String) throws -> String? {
        try ResponseFormat.grammar(for: Data(#"{"messages":[],"response_format":\#(format)}"#.utf8))
    }

    func schema(_ schema: String) throws -> String {
        try #require(try grammar(#"{"type":"json_schema","json_schema":{"name":"x","strict":true,"schema":\#(schema)}}"#))
    }

    @Test func textNeedsNoGrammar() throws {
        #expect(try ResponseFormat.grammar(for: Data(#"{"messages":[]}"#.utf8)) == nil)
        #expect(try grammar(#"{"type":"text"}"#) == nil)
        #expect(try grammar("null") == nil)
        // As llama-server does: what isn't an object, or names no type, asks
        // for nothing.
        #expect(try grammar(#""json""#) == nil)
        #expect(try grammar("{}") == nil)
    }

    @Test func aSchemaBecomesAGrammar() throws {
        let made = try schema(#"""
            {"type":"object","properties":{"subject":{"type":"string"},
             "camera":{"enum":["close","wide"]},"note":{"type":"string"}},
             "required":["subject","camera"],"additionalProperties":false}
            """#)
        #expect(made == #"""
            camera ::= ("\"close\"" | "\"wide\"")
            camera-kv ::= "\"camera\"" space ":" space camera
            char ::= [^"\\\x7F\x00-\x1F] | [\\] (["\\bfnrt] | "u" [0-9a-fA-F]{4})
            note-kv ::= "\"note\"" space ":" space string
            root ::= "{" space subject-kv "," space camera-kv ( "," space ( note-kv ) )? space "}"
            space ::= | " " | "\n"{1,2} [ \t]{0,20}
            string ::= "\"" char* "\""
            subject-kv ::= "\"subject\"" space ":" space string

            """#)
    }

    /// A model writes the earlier properties first, so their order is the
    /// schema's, not alphabetical.
    @Test func propertiesKeepTheSchemasOrder() throws {
        let made = try schema(#"""
            {"type":"object","properties":{"zebra":{"type":"string"},"apple":{"type":"string"},
             "mango":{"type":"string"}},"required":["zebra","apple","mango"]}
            """#)
        #expect(made.contains(#"root ::= "{" space zebra-kv "," space apple-kv "," space mango-kv space "}""#))
    }

    @Test func optionalPropertiesComeInOrderEachAtMostOnce() throws {
        let made = try schema(#"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}}}"#)
        #expect(made.contains(#"root ::= "{" space  (a-kv a-rest | b-kv )? space "}""#))
        #expect(made.contains(#"a-rest ::= ( "," space b-kv )?"#))
    }

    /// As llama-server reads them.
    @Test func jsonObjectAndASchemalessJSONSchemaAreAnyObject() throws {
        for format in [#"{"type":"json_object"}"#, #"{"type":"json_schema","json_schema":{"name":"x"}}"#,
                       #"{"type":"json_schema","json_schema":{"schema":{}}}"#] {
            #expect(try grammar(format)?.contains("root ::= object\n") == true, "\(format)")
        }
    }

    @Test func arraysAndStringsKeepTheirLimits() throws {
        let made = try schema(#"{"type":"array","items":{"type":"string","minLength":2,"maxLength":5},"minItems":1,"maxItems":3}"#)
        #expect(made.contains(#"root ::= "[" space item ("," space item){0,2} space "]""#))
        #expect(made.contains(#"item ::= "\"" char{2,5} "\"""#))
    }

    @Test func integersKeepTheirBounds() throws {
        #expect(try schema(#"{"type":"integer","minimum":0}"#).contains("root ::= ([0] | [1-9] [0-9]{0,15})\n"))
        #expect(try schema(#"{"type":"integer","minimum":-5,"maximum":5}"#).contains(#"root ::= ("-" ([0-5]) | [0-5])"#))
    }

    @Test func formatsAreEnforced() throws {
        #expect(try schema(#"{"type":"string","format":"date"}"#).contains(#"root ::= date-string"#))
        #expect(try schema(#"{"type":"string","format":"uuid"}"#).hasPrefix(#"root ::= "\"" [0-9a-fA-F]{8}"#))
    }

    @Test func referencesMayRecurse() throws {
        let made = try schema(#"""
            {"$defs":{"node":{"type":"object","properties":{"children":{"type":"array","items":{"$ref":"#/$defs/node"}}},
             "required":["children"]}},"$ref":"#/$defs/node"}
            """#)
        #expect(made.contains("root ::= ref-defs-node\n"))
        #expect(made.contains("ref-defs-node-children-item ::= ref-defs-node\n"))
    }

    /// Written as llama.cpp's JSON library writes it, so 2.50 is 2.5.
    @Test func constantsAreExact() throws {
        #expect(try schema(#"{"const":{"b":[1,2.50],"a":"x\"y"}}"#)
            .hasPrefix(#"root ::= "{\"b\":[1,2.5],\"a\":\"x\\\"y\"}""#))
    }

    @Test func additionalPropertiesAreNotTheNamedOnes() throws {
        let made = try schema(#"{"type":"object","properties":{"ab":{"type":"boolean"}},"required":["ab"],"additionalProperties":{"type":"integer"}}"#)
        #expect(made.contains(#"additional-k ::= ["] ( [a] ([b] char+ | [^"b] char*) | [^"a] char* )? ["]"#))
        #expect(made.contains(#"root ::= "{" space ab-kv ( "," space ( additional-kv ( "," space additional-kv )* ) )? space "}""#))
    }

    @Test func malformedSchemasAreTheClients() {
        #expect(throws: ResponseFormat.Failure.invalid(#"response_format type must be one of "text", "json_object" or "json_schema", not xml"#)) {
            try grammar(#"{"type":"xml"}"#)
        }
        #expect(throws: ResponseFormat.Failure.invalid("JSON schema error at #: unrecognized type kaboom")) {
            try schema(#"{"type":"kaboom"}"#)
        }
        #expect(throws: ResponseFormat.Failure.invalid("JSON schema error at #: type must be a string or an array of strings")) {
            try schema(#"{"type":123}"#)
        }
        #expect(throws: ResponseFormat.Failure.invalid("JSON schema error at #: minItems must be a non-negative integer")) {
            try schema(#"{"type":"array","minItems":1.5}"#)
        }
        #expect(throws: ResponseFormat.Failure.invalid("JSON schema property name is longer than 128 chars")) {
            try schema(#"{"type":"object","properties":{"\#(String(repeating: "a", count: 1000))":{"type":"string"}},"additionalProperties":true}"#)
        }
    }

    /// Refused rather than ignored, so the answer never silently breaks the
    /// schema. The gateway tries another host.
    @Test func whatThisHostDoesntEnforce() {
        #expect(throws: ResponseFormat.Failure.unsupported("this host doesn't enforce pattern in a response_format schema")) {
            try schema(#"{"type":"object","properties":{"id":{"type":"string","pattern":"^[a-z]+$"}}}"#)
        }
        #expect(throws: ResponseFormat.Failure.self) { try schema(#"{"$ref":"https://example.com/s.json"}"#) }
    }
}

@Suite struct OrderedJSONTests {
    @Test func keepsKeyOrder() throws {
        let value = try OrderedJSON.parse(Data(#" {"z": 1, "a": [true, null, -2.5e3], "m": {"y": "", "b": {}}} "#.utf8))
        guard case .object(let members) = value else {
            Issue.record("\(value)")
            return
        }
        #expect(members.map(\.key) == ["z", "a", "m"])
        #expect(value.dumped == #"{"z":1,"a":[true,null,-2500.0],"m":{"y":"","b":{}}}"#)
    }

    @Test func decodesEscapes() throws {
        let value = try OrderedJSON.parse(Data(#""a\"b\\c\/d\né😀\u0001""#.utf8))
        #expect(value == .string("a\"b\\c/d\né😀\u{01}"))
        #expect(value.dumped == #""a\"b\\c/d\né😀\u0001""#)
    }

    @Test func refusesWhatIsntJSON() {
        for text in ["", "{", #"{"a" 1}"#, "[1,]", "1x", "-", #""\x""#, #""\u12G4""#, #""\u+123""#, "tru", "{} {}",
                     String(repeating: "[", count: 200) + String(repeating: "]", count: 200)] {
            #expect(throws: OrderedJSON.Malformed.self, "\(text)") { try OrderedJSON.parse(Data(text.utf8)) }
        }
    }
}
