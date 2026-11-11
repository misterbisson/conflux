import Foundation

/// The version the app shows its owner: release-please's version, and Xcode
/// Cloud's build number, which tells two TestFlight builds of one version
/// apart.
public enum AppVersion {
    /// This app's, from its Info.plist.
    public static var current: String { label(Bundle.main.infoDictionary ?? [:]) }

    /// "0.4.3 (12)": the version, then the build. Built from source with
    /// `swift build`, there's no Info.plist to read.
    public static func label(_ info: [String: Any]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return "Built from source"
        }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }
}
