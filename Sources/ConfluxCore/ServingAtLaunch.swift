import Foundation

/// Whether the app was serving when it last quit, so it serves again when it
/// next opens. Recorded at every start, stop and change of intent, not only
/// at quit, so a crash or a forced quit keeps the last state the owner chose.
///
/// Only serving counts. A Mac its owner stopped, paused or drained stays that
/// way: an app launching conflux doesn't decide that a model loads.
public struct ServingAtLaunch {
    public static let key = "servingAtLaunch"
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether to start when the app opens. False until it has served once.
    public var resumes: Bool { defaults.bool(forKey: Self.key) }

    public func record(running: Bool, intent: OwnerIntent) {
        defaults.set(running && intent == .serving, forKey: Self.key)
    }
}
