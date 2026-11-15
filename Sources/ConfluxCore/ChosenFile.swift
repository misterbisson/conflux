import Foundation

/// A file chosen on one launch, to find among the files listed on the next.
/// Its path can change between launches while it stays the same file: an
/// app update moves the app, and with it the starter model, and can move the
/// app's container, and with it the files copied in. So it's found by its
/// path, or failing that by its folder and name, or by its name alone when
/// only one file has it.
public struct ChosenFile: Codable, Equatable, Sendable {
    public var path: String

    public init(_ url: URL) {
        path = url.standardizedFileURL.path
    }

    public func find(in urls: [URL]) -> URL? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        if let same = urls.first(where: { $0.standardizedFileURL.path == path }) { return same }
        let named = urls.filter { $0.lastPathComponent == name }
        if let inFolder = named.first(where: { $0.deletingLastPathComponent().lastPathComponent == folder }) {
            return inFolder
        }
        return named.count == 1 ? named[0] : nil
    }
}

/// The model file last chosen to serve, and how, for the next launch.
public struct ChosenModelFile: Codable, Equatable, Sendable {
    public var model: ChosenFile
    /// Nil for text only.
    public var projector: ChosenFile?
    public var slots: Int
    public var contextPerSlot: Int

    public init(model: URL, projector: URL?, slots: Int, contextPerSlot: Int) {
        self.model = ChosenFile(model)
        self.projector = projector.map(ChosenFile.init)
        self.slots = slots
        self.contextPerSlot = contextPerSlot
    }
}
