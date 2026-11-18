import Foundation

/// Gemma 4's chat template, for the in-process runtime.
///
/// `llama_chat_apply_template` formats prompts from a fixed list of
/// templates it recognizes, and llama.cpp build 12110's list has no Gemma 4:
/// its template is Jinja, which only `llama-server` runs. So conflux
/// formats Gemma 4's prompts itself, as the model's own template does with
/// thinking off and no tools, which `llama-server -- --reasoning off`
/// renders the same way.
///
/// Two things follow the in-process runtime rather than `llama-server`:
/// text parts are joined with a newline, as `ChatCompletionRequest.parse`
/// joins them for every model, where Gemma 4's template runs them
/// together; and a last message from the assistant is a turn of its own,
/// not the start of the answer.
enum Gemma4Template {
    /// Whether `template`, a model's chat template, is Gemma 4's: it marks
    /// turns `<|turn>` and `<turn|>`.
    static func matches(_ template: String) -> Bool {
        template.contains("<|turn>") && template.contains("<turn|>")
    }

    /// The messages, ready for the model's answer. The tokenizer adds the
    /// `<bos>` the template starts with.
    static func format(_ messages: [ChatCompletionRequest.Message]) -> String {
        var prompt = ""
        var messages = messages[...]
        // Only a first system message is the system turn. The request
        // parser has made developer messages system ones.
        if let first = messages.first, first.role == "system" {
            prompt += "<|turn>system\n" + trimmed(first.text) + "<turn|>\n"
            messages = messages.dropFirst()
        }
        // The template shows a tool's message only as the answer to a tool
        // call, and conflux makes none.
        let turns = messages.filter { $0.role != "tool" }
        for (index, message) in turns.enumerated() {
            let role = message.role == "assistant" ? "model" : message.role
            let previous = index > 0 ? turns[index - 1].role : nil
            let next = index + 1 < turns.count ? turns[index + 1].role : nil
            // The assistant's messages in a row are one turn.
            if !(role == "model" && previous == "assistant") {
                prompt += "<|turn>" + role + "\n"
            }
            prompt += role == "model" ? withoutThinking(message.text) : trimmed(message.text)
            if !(role == "model" && next == "assistant") {
                prompt += "<turn|>\n"
            }
        }
        // An empty thought: the model answers without thinking first.
        return prompt + "<|turn>model\n<|channel>thought\n<channel|>"
    }

    /// The assistant's text without its thinking, `<|channel>…<channel|>`,
    /// as the template keeps earlier answers.
    static func withoutThinking(_ text: String) -> String {
        let kept = text.components(separatedBy: "<channel|>").map { part in
            part.range(of: "<|channel>").map { String(part[..<$0.lowerBound]) } ?? part
        }
        return trimmed(kept.joined())
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
