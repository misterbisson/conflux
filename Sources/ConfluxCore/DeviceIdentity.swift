import CryptoKit
import Foundation
import Security

/// This device's iroh identity: a secret key that never leaves the device,
/// and the endpoint ID that is its public half.
///
/// The key is kept in the keychain as `ThisDeviceOnly`, never synced, so the
/// ID is stable across launches and no two devices can answer as one
/// (docs/design.md, *Trust*). The data protection keychain needs a signed
/// app; built from source (`swift run`), conflux keeps the key in a file only
/// this user can read, as it does the gateway's token.
public struct DeviceIdentity: Sendable, Equatable {
    /// 32 bytes. Whoever has them can answer as this device.
    let secretKey: Data
    /// 64 lowercase hex characters: the Ed25519 public key, as iroh names
    /// endpoints.
    public let endpointID: String

    init(secretKey: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)
        self.secretKey = secretKey
        endpointID = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// A new identity, kept nowhere. For tests.
    public static func ephemeral() -> DeviceIdentity {
        // Force-try: a fresh key's raw representation is always a valid key.
        try! DeviceIdentity(secretKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    /// This device's identity, made and stored the first time. `label` keeps
    /// separate identities apart, so two nodes can run on one Mac.
    public static func load(label: String = "default") throws -> DeviceIdentity {
        let store = IdentityStore(label: label)
        if let key = try store.read() { return try DeviceIdentity(secretKey: key) }
        let identity = ephemeral()
        try store.write(identity.secretKey)
        return identity
    }

    /// The first characters of the ID, enough to tell devices apart on screen.
    public static func short(_ id: String) -> String { String(id.prefix(10)) }

    public static func isEndpointID(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Where the secret key is kept.
struct IdentityStore {
    let label: String
    static let service = "conflux.device-key"

    var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "conflux/identity/\(label).key")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: label,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() throws -> Data? {
        var result: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        switch SecItemCopyMatching(search as CFDictionary, &result) {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            // Without the entitlement, a read finds nothing rather than
            // failing, and the key is in the file if anywhere.
            return try? Data(contentsOf: fileURL)
        case let status:
            throw IdentityError.keychain(status)
        }
    }

    /// The keychain access group the key is kept in: the app's own, named
    /// `<team prefix>.<bundle ID>`. Nil when it isn't in the keychain.
    var accessGroup: String? {
        var result: CFTypeRef?
        var search = query
        search[kSecReturnAttributes as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    func write(_ key: Data) throws {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "conflux device key"
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecMissingEntitlement:
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: fileURL.path, contents: key, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        case let status:
            throw IdentityError.keychain(status)
        }
    }
}

enum IdentityError: Error, CustomStringConvertible {
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .keychain(let status):
            "the keychain refused the device key: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")"
        }
    }
}
