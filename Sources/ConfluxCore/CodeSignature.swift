#if os(macOS)
import Foundation
import Security

/// Which app a bundle on disk, or a running process, is, from its code
/// signature: what pairing asks the person about, and gives a token to.
/// Nothing here encrypts anything: it checks signatures.
public enum CodeSignature {
    /// The app at a bundle URL, if its signature is valid.
    public static func app(at url: URL) -> AppIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              // The signature and the executable, not every resource:
              // enough to trust the identifier and team, and quick for a
              // big app.
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
                == errSecSuccess
        else { return nil }
        return identity(of: code, bundle: url)
    }

    /// Who a running process is, from its audit token: the app it is, when
    /// it's an app's own executable, or not an app.
    ///
    /// Whether it's an app is decided by where its executable is, which the
    /// kernel says, not by whether its signature can be read: the sandbox
    /// can't read code outside the system's folders and /Applications, and
    /// an app conflux can't check is refused, not taken for a tool.
    public static func process(auditToken: Data) -> Pairing.Requester {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return .notAnApp }
        // audit_token_t's sixth word is the process ID.
        let pid = auditToken.withUnsafeBytes { $0.load(fromByteOffset: 5 * 4, as: Int32.self) }
        // Gone already, or hidden: who asked can't be told, so it's refused.
        guard let executable = executablePath(pid) else { return .invalid }
        guard let bundle = appBundle(executable: executable) else { return .notAnApp }
        var guest: SecCode?
        var code: SecStaticCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
              SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              let identity = identity(of: code, bundle: bundle)
        else { return .invalid }
        return .app(identity)
    }

    /// The bundle an app's own executable is in, `<name>.app/Contents/MacOS/<executable>`,
    /// or nil for anything else: a tool, or a helper that isn't an app's
    /// main executable.
    static func appBundle(executable: URL) -> URL? {
        let parts = executable.standardizedFileURL.pathComponents
        guard parts.count >= 4, parts[parts.count - 2] == "MacOS", parts[parts.count - 3] == "Contents",
              parts[parts.count - 4].hasSuffix(".app")
        else { return nil }
        return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func executablePath(_ pid: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return URL(filePath: String(decoding: buffer.prefix(Int(count)), as: UTF8.self))
    }

    /// The process's own audit token, for testing what `process` makes of it.
    static func ownAuditToken() -> Data? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    static func identity(of code: SecStaticCode, bundle: URL) -> AppIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let information = information as? [String: Any],
              // The identifier it's signed with, which is in the signature:
              // for an app, its bundle ID.
              let identifier = information[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        let plist = information[kSecCodeInfoPList as String] as? [String: Any]
        let name = plist?["CFBundleDisplayName"] as? String ?? plist?["CFBundleName"] as? String
            ?? FileManager.default.displayName(atPath: bundle.path)
        return AppIdentity(bundleID: identifier, teamID: team, name: name)
    }
}
#endif
