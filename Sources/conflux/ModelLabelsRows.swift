import ConfluxCore
import SwiftUI

/// A model's rows for which requests reach it: what it reads, from its
/// files; whether it answers any request or only when asked for; and the
/// work its owner trusts it with (docs/design.md, Capabilities and tags).
/// They change at once, while conflux runs.
struct ModelLabelsRows: View {
    let modelID: String
    let readsImages: Bool
    /// Tokens of context per slot, for what it reads. Nil leaves that row
    /// out.
    let contextTokens: Int?
    @Binding var labels: ModelLabels

    @State private var newTag = ""
    @State private var tagProblem: String?

    var body: some View {
        if let contextTokens {
            LabeledContent("Reads") {
                Text("\(readsImages ? "Text and images" : "Text"), \(contextTokens.formatted()) tokens per slot")
            }
            Text("From the model's files and settings. Clients can ask for \(facts(contextTokens)).")
                .font(.caption).foregroundStyle(.secondary)
        }

        Picker("Answers", selection: Binding(get: { labels.onlyWhenAsked }, set: { labels = labels.held($0) })) {
            Text("Requests for any model").tag(false)
            Text("Only requests that ask for it").tag(true)
        }
        Text(labels.onlyWhenAsked
             ? "Left out of any and \(readsImages ? "any-vision" : "the other any aliases"), so its slots stay free for requests that name it or one of its tags."
             : "Answers any and \(readsImages ? "any-vision" : "the other any aliases"), as well as its tags.")
            .font(.caption).foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
            Text("Trusted with")
            ForEach(ModelTag.vocabulary.filter { readsImages || !$0.needsVision }) { tag in
                Toggle(isOn: Binding(get: { labels.tags.contains(tag.id) }, set: { labels = labels.with(tag.id, $0) })) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(tag.id).font(.body.monospaced())
                        Text(tag.promise).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }

        LabeledContent("Other tags") {
            HStack {
                ForEach(custom, id: \.self) { tag in
                    HStack(spacing: 2) {
                        Text(tag).font(.caption.monospaced())
                        Button { labels = labels.with(tag, false) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).font(.caption2)
                            .help("Remove \(tag)")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                TextField("Other tags", text: $newTag, prompt: Text("add a tag"))
                    .labelsHidden().frame(width: 110)
                    .onSubmit(add)
                    .onChange(of: newTag) { tagProblem = nil }
            }
        }
        if let tagProblem {
            Text(tagProblem).font(.caption).foregroundStyle(.red)
        }
        Text("""
            Your judgement, not conflux's. Clients rely on the tags above meaning the same in every mesh; \
            your own mean what you say, in your mesh only. Tags change while conflux runs.
            """)
            .font(.caption).foregroundStyle(.secondary)

        LabeledContent("Clients reach it with") {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(reachedWith, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }

    /// The owner's own tags, beside the vocabulary's.
    var custom: [String] { labels.tags.filter { !ModelTag.isDocumented($0) } }

    func facts(_ contextTokens: Int) -> String {
        let context = "context-\(max(1, contextTokens / 1024))k"
        return readsImages ? "vision and \(context)" : context
    }

    /// What a client can send in `model` to reach it.
    var reachedWith: [String] {
        var names = [modelID]
        if !labels.onlyWhenAsked { names += readsImages ? ["any", "any-vision"] : ["any"] }
        names += labels.tags.filter { readsImages || !ModelTag.needsVision($0) }.map { "any+\($0)" }
        return names
    }

    /// Adds the tag typed, ticking it instead if it's one of the vocabulary's.
    func add() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        if ModelTag.isDocumented(tag) {
            labels = labels.with(tag, true)
        } else if let problem = ModelTag.problem(withCustom: tag) {
            tagProblem = problem
            return
        } else {
            labels = labels.with(tag, true)
        }
        newTag = ""
    }
}
