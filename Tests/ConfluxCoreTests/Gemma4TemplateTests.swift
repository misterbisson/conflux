import Foundation
import Testing
@testable import ConfluxCore

/// The expected prompts are what `llama-server -- --reasoning off` renders
/// from Gemma 4 26B-A4B's own template, through its `/apply-template`, for
/// the same messages: llama.cpp build 11669, the model's template
/// published 2026-07-09.
@Suite struct Gemma4TemplateTests {
    func prompt(_ json: String) throws -> String {
        let body = #"{"messages":"# + json + "}"
        return Gemma4Template.format(try ChatCompletionRequest.parse(Data(body.utf8), marker: "<m>").messages)
    }

    static let pixel = "data:image/png;base64," + Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    static let answer = "<|turn>model\n<|channel>thought\n<channel|>"

    @Test func recognizesGemma4() {
        #expect(Gemma4Template.matches("{{- bos_token -}}{{- '<|turn>' + role + '\\n' }}{{- '<turn|>\\n' -}}"))
        #expect(!Gemma4Template.matches("{{ '<start_of_turn>' + role + '\\n' }}{{ '<end_of_turn>\\n' }}"))
        #expect(!Gemma4Template.matches("{% for message in messages %}<|im_start|>{% endfor %}"))
    }

    @Test func aUserMessage() throws {
        #expect(try prompt(#"[{"role":"user","content":"Hello there"}]"#)
            == "<|turn>user\nHello there<turn|>\n" + Self.answer)
    }

    @Test func aSystemMessageFirstIsTheSystemTurn() throws {
        #expect(try prompt(#"[{"role":"system","content":"  Be brief.  "},{"role":"user","content":" Hi \n"}]"#)
            == "<|turn>system\nBe brief.<turn|>\n<|turn>user\nHi<turn|>\n" + Self.answer)
        #expect(try prompt(#"[{"role":"developer","content":"Dev says"},{"role":"user","content":"Hi"}]"#)
            == "<|turn>system\nDev says<turn|>\n<|turn>user\nHi<turn|>\n" + Self.answer)
    }

    @Test func aLaterSystemMessageIsATurnOfItsOwn() throws {
        #expect(try prompt(#"[{"role":"user","content":"A"},{"role":"system","content":"B"},{"role":"user","content":"C"}]"#)
            == "<|turn>user\nA<turn|>\n<|turn>system\nB<turn|>\n<|turn>user\nC<turn|>\n" + Self.answer)
    }

    @Test func images() throws {
        let imageFirst = #"[{"role":"user","content":[{"type":"image_url","image_url":{"url":"\#(Self.pixel)"}},"#
            + #"{"type":"text","text":"Describe this image."}]}]"#
        #expect(try prompt(imageFirst) == "<|turn>user\n<m>Describe this image.<turn|>\n" + Self.answer)

        let imageLast = #"[{"role":"user","content":[{"type":"text","text":"Look:"},"#
            + #"{"type":"image_url","image_url":{"url":"\#(Self.pixel)"}}]}]"#
        #expect(try prompt(imageLast) == "<|turn>user\nLook:<m><turn|>\n" + Self.answer)

        let spaced = #"[{"role":"user","content":[{"type":"text","text":" Look: "},"#
            + #"{"type":"image_url","image_url":{"url":"\#(Self.pixel)"}},{"type":"text","text":" more "}]}]"#
        #expect(try prompt(spaced) == "<|turn>user\nLook: <m> more<turn|>\n" + Self.answer)
    }

    @Test func aConversation() throws {
        #expect(try prompt(#"[{"role":"user","content":"One"},{"role":"assistant","content":" Two "},{"role":"user","content":"Three"}]"#)
            == "<|turn>user\nOne<turn|>\n<|turn>model\nTwo<turn|>\n<|turn>user\nThree<turn|>\n" + Self.answer)
    }

    @Test func theAssistantsMessagesInARowAreOneTurn() throws {
        let json = #"[{"role":"user","content":"A"},{"role":"assistant","content":"B"},"#
            + #"{"role":"assistant","content":"C"},{"role":"user","content":"D"}]"#
        #expect(try prompt(json) == "<|turn>user\nA<turn|>\n<|turn>model\nBC<turn|>\n<|turn>user\nD<turn|>\n" + Self.answer)
    }

    @Test func earlierThinkingIsLeftOut() throws {
        let json = #"[{"role":"user","content":"A"},{"role":"assistant","content":"<|channel>thought\nhmm<channel|>Answer"},"#
            + #"{"role":"user","content":"D"}]"#
        #expect(try prompt(json) == "<|turn>user\nA<turn|>\n<|turn>model\nAnswer<turn|>\n<|turn>user\nD<turn|>\n" + Self.answer)
        #expect(Gemma4Template.withoutThinking(" a<|channel>x<channel|>b<|channel>y<channel|> c ") == "ab c")
        #expect(Gemma4Template.withoutThinking("no thinking") == "no thinking")
    }

    @Test func anEmptyMessage() throws {
        #expect(try prompt(#"[{"role":"user","content":""}]"#) == "<|turn>user\n<turn|>\n" + Self.answer)
    }

    /// Where the in-process runtime keeps its own behavior: a last message
    /// from the assistant is a turn, and text parts join with a newline.
    @Test func whereItDiffersFromLlamaServer() throws {
        #expect(try prompt(#"[{"role":"user","content":"A"},{"role":"assistant","content":"B"}]"#)
            == "<|turn>user\nA<turn|>\n<|turn>model\nB<turn|>\n" + Self.answer)
        #expect(try prompt(#"[{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]"#)
            == "<|turn>user\na\nb<turn|>\n" + Self.answer)
    }

    @Test func toolMessagesAreLeftOut() throws {
        #expect(try prompt(#"[{"role":"user","content":"A"},{"role":"tool","content":"B"}]"#)
            == "<|turn>user\nA<turn|>\n" + Self.answer)
    }
}
