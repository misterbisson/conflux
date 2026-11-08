import Foundation

/// The small model the app ships, so a first request works before anyone has
/// chosen a model: SmolVLM-256M-Instruct, by Hugging Face, Apache 2.0, with
/// its vision projector, about 280 MB.
///
/// It reads text and images, and passes the self-check, but its answers are
/// weak: it shows the gateway, the host and a client working together, not
/// what a real model can do. The app serves it until the person chooses
/// another.
///
/// `tools/ci/fetch-starter-model.sh` fetches it, pinned by revision and
/// checksum, and the app targets copy it into the app. Built with
/// `swift build` there's no app bundle, so no starter model.
public enum StarterModel {
    /// The folder in the app's resources.
    public static let folder = "StarterModel"
    public static let modelFile = "SmolVLM-256M-Instruct-Q8_0.gguf"
    public static let projectorFile = "mmproj-SmolVLM-256M-Instruct-Q8_0.gguf"

    /// The starter model's files in `bundle`, or nil when it has none.
    public static func files(in bundle: Bundle = .main) -> (model: String, projector: String)? {
        guard let resources = bundle.resourceURL?.appending(path: folder) else { return nil }
        let model = resources.appending(path: modelFile).path
        let projector = resources.appending(path: projectorFile).path
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: model), manager.isReadableFile(atPath: projector) else { return nil }
        return (model, projector)
    }

    /// `config` serving the starter model, keeping its other settings.
    public static func serving(_ files: (model: String, projector: String), from config: ModelConfig) -> ModelConfig {
        var config = config
        config.model = files.model
        config.projector = files.projector
        return config
    }
}
