import Foundation

/// A GGUF file, and what its header says about it.
public struct GGUFFile: Sendable, Equatable {
    public var url: URL
    public var metadata: Result<GGUFMetadata, GGUFError>

    public init(url: URL, metadata: Result<GGUFMetadata, GGUFError>) {
        self.url = url
        self.metadata = metadata
    }

    /// The file at `url`, its header read once for each version of the file.
    public init(_ url: URL) {
        self.init(url: url, metadata: GGUFMetadata.cached(url))
    }

    public var name: String { url.lastPathComponent }

    /// Whether it's a multimodal projector: its header says so. Only when the
    /// header can't be read does the name decide, by llama.cpp's convention
    /// of `mmproj` in a projector's name.
    public var isProjector: Bool {
        switch metadata {
        case .success(let metadata): metadata.isProjector
        case .failure: name.lowercased().contains("mmproj")
        }
    }
}

/// Which projector goes with which model.
///
/// A projector turns an image into vectors the model reads, so it fits a
/// model when its output is as wide as the model's embeddings. llama.cpp's
/// converter writes both widths in the headers. One made for another model
/// fails to load, or loads and makes no sense of images.
public enum Projectors {
    /// Whether `projector` fits `model`, or nil when the headers don't say.
    public static func fits(_ projector: GGUFMetadata, _ model: GGUFMetadata) -> Bool? {
        guard projector.readsImages, !model.isProjector, let width = projector.imageWidth,
              let embedding = model.embeddingLength else { return nil }
        return width == embedding
    }

    /// The projector among `projectors` made for `model`, or nil.
    ///
    /// Only projectors that fit are suggested. When more than one does, the
    /// names break the tie: the projector whose `general.basename` matches
    /// the model's, then whose `general.name` does, then whose file name
    /// shares the longest start with the model's. If that still ties, or none
    /// fits, there's no suggestion: a wrong one is worse than none.
    public static func suggestion(for model: GGUFFile, among projectors: [GGUFFile]) -> URL? {
        guard case .success(let modelMetadata) = model.metadata else { return nil }
        let fitting = projectors.compactMap { file -> (GGUFFile, GGUFMetadata)? in
            guard case .success(let metadata) = file.metadata, fits(metadata, modelMetadata) == true else { return nil }
            return (file, metadata)
        }
        guard fitting.count > 1 else { return fitting.first?.0.url }
        let ranked = fitting.map { file, metadata in
            (file.url, likeness(of: file, metadata, to: model, modelMetadata))
        }.sorted { $0.1 > $1.1 }
        guard ranked[0].1 > ranked[1].1 else { return nil }
        return ranked[0].0
    }

    /// How alike a projector's names are to a model's, to compare
    /// projectors that both fit.
    private static func likeness(of projector: GGUFFile, _ metadata: GGUFMetadata, to model: GGUFFile,
                                 _ modelMetadata: GGUFMetadata) -> Likeness {
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        let a = stem(projector.name), b = stem(model.name)
        return Likeness(basename: same(metadata.basename, modelMetadata.basename),
                        name: same(metadata.name, modelMetadata.name),
                        sharedStart: zip(a, b).prefix { $0 == $1 }.count)
    }

    private struct Likeness: Comparable {
        var basename: Bool
        var name: Bool
        var sharedStart: Int

        static func < (l: Likeness, r: Likeness) -> Bool {
            (l.basename ? 1 : 0, l.name ? 1 : 0, l.sharedStart) < (r.basename ? 1 : 0, r.name ? 1 : 0, r.sharedStart)
        }
    }

    /// A file name without `mmproj`, case, punctuation or extension:
    /// `mmproj-SmolVLM-256M-f16.gguf` is `smolvlm256mf16`.
    private static func stem(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".gguf") { name.removeLast(5) }
        return String(name.replacingOccurrences(of: "mmproj", with: "").filter { $0.isLetter || $0.isNumber })
    }

    /// What's wrong with serving `model` with `projector`, in words for the
    /// window: a model that's a projector, a projector that isn't one or
    /// doesn't fit, or a file whose header can't be read. Empty when nothing
    /// is known to be wrong.
    public static func problems(model: GGUFFile?, projector: GGUFFile?) -> [String] {
        var problems: [String] = []
        let modelMetadata: GGUFMetadata?
        switch model?.metadata {
        case .success(let metadata)?:
            modelMetadata = metadata
            if metadata.isProjector, let model {
                problems.append("\(model.name) is a projector, not a model. Choose the model it goes with as the "
                    + "model, and this as its projector.")
            }
        case .failure(let error)?:
            modelMetadata = nil
            if let model { problems.append("conflux can't read \(model.name): \(error.localizedDescription).") }
        case nil:
            modelMetadata = nil
        }
        guard let projector else { return problems }
        switch projector.metadata {
        case .success(let metadata):
            if !metadata.isProjector {
                problems.append("\(projector.name) is a model, not a projector. A projector usually has "
                    + "\"mmproj\" in its name.")
            } else if !metadata.readsImages {
                problems.append("\(projector.name) reads audio, not images. conflux needs a projector that "
                    + "reads images.")
            } else if let modelMetadata, let model, !modelMetadata.isProjector, fits(metadata, modelMetadata) == false,
                      let width = metadata.imageWidth, let embedding = modelMetadata.embeddingLength {
                problems.append("\(projector.name) was made for another model: it gives the model vectors "
                    + "\(width) wide, and \(model.name) takes \(embedding). Choose the projector made for "
                    + "this model.")
            }
        case .failure(let error):
            problems.append("conflux can't read \(projector.name): \(error.localizedDescription).")
        }
        return problems
    }
}
