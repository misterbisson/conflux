import Foundation
import Security

/// A device as it listed itself: its endpoint ID, the public half of a key
/// that never leaves it, a name to show, and when it last said so.
public struct ListedDevice: Sendable, Equatable, Identifiable {
    public var id: String { endpointID }
    public let endpointID: String
    public var name: String
    public var published: Date

    public init(endpointID: String, name: String, published: Date = Date()) {
        self.endpointID = endpointID
        self.name = name
        self.published = published
    }

    /// A device that hasn't refreshed its listing for this long is treated
    /// as gone: trusted by nobody, and shown nowhere.
    public static let staleAfter: TimeInterval = 30 * 24 * 3600
    /// How often a running device refreshes its listing.
    public static let refreshAfter: TimeInterval = 24 * 3600
}

/// Where each of the user's devices lists itself, and so whom this device
/// trusts (docs/design.md, *Trust*). The signed app keeps it in iCloud
/// Keychain; tests use `MemoryDeviceDirectory`.
///
/// Calls may block briefly: keep them off the main thread.
public protocol DeviceDirectory: Sendable {
    /// Every device listed, this one included.
    func devices() throws -> [ListedDevice]
    /// Lists a device, or replaces its listing.
    func publish(_ device: ListedDevice) throws
    /// Removes a device's listing, on every device. Removing one that isn't
    /// listed does nothing.
    func remove(_ endpointID: String) throws
}

/// Whether this device is in the directory.
public enum Membership: Sendable, Equatable {
    /// Listed, and its listing is fresh.
    case listed
    /// It listed itself before, and the listing is gone: another device
    /// forgot it. It stays out until its owner turns the directory on again.
    case forgotten
}

extension DeviceDirectory {
    /// Keeps this device's listing: lists it the first time, refreshes it
    /// when old or renamed, and leaves it out if another device forgot it.
    ///
    /// `listedBefore` is the endpoint ID this device last listed, kept by the
    /// caller between launches. Its listing gone while that's set means it
    /// was forgotten, rather than never listed.
    public func keepListed(_ endpointID: String, name: String, listedBefore: String?,
                           now: Date = Date()) throws -> Membership {
        if let own = try devices().first(where: { $0.endpointID == endpointID }) {
            if own.name != name || now.timeIntervalSince(own.published) > ListedDevice.refreshAfter {
                try publish(ListedDevice(endpointID: endpointID, name: name, published: now))
            }
            return .listed
        }
        if listedBefore == endpointID { return .forgotten }
        try publish(ListedDevice(endpointID: endpointID, name: name, published: now))
        return .listed
    }

    /// The devices this one should trust: listed recently, not itself.
    public func others(than endpointID: String?, now: Date = Date()) throws -> [ListedDevice] {
        try devices().filter {
            $0.endpointID != endpointID && DeviceIdentity.isEndpointID($0.endpointID)
                && now.timeIntervalSince($0.published) <= ListedDevice.staleAfter
        }
        .sorted { $0.endpointID < $1.endpointID }
    }
}

/// A directory in memory, for tests, and for showing what a directory does
/// without the entitlement a keychain one needs.
public final class MemoryDeviceDirectory: DeviceDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [String: ListedDevice]
    /// Thrown by every call while set, to stand in for a keychain that can't
    /// be read.
    public var failure: (any Error)? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    private var _failure: (any Error)?

    public init(_ devices: [ListedDevice] = []) {
        listed = Dictionary(devices.map { ($0.endpointID, $0) }, uniquingKeysWith: { $1 })
    }

    public func devices() throws -> [ListedDevice] {
        try lock.withLock {
            if let _failure { throw _failure }
            return Array(listed.values)
        }
    }

    public func publish(_ device: ListedDevice) throws {
        try lock.withLock {
            if let _failure { throw _failure }
            listed[device.endpointID] = device
        }
    }

    public func remove(_ endpointID: String) throws {
        try lock.withLock {
            if let _failure { throw _failure }
            listed[endpointID] = nil
        }
    }
}

/// The directory in iCloud Keychain: one synchronizable generic password per
/// device, in an access group every build of the app shares.
///
/// - service: `conflux.device`
/// - account: the endpoint ID, 64 hex characters
/// - data: JSON, `{"name": …, "published": …}`, the date in ISO 8601
///
/// Only the public endpoint ID is synced. The secret key is a separate item,
/// `ThisDeviceOnly` (`DeviceIdentity`).
public struct KeychainDeviceDirectory: DeviceDirectory {
    public static let service = "conflux.device"
    /// The access group, after the team's prefix. App/conflux.entitlements
    /// gives it as `$(AppIdentifierPrefix)com.caseybisson.conflux.devices`.
    public static let group = "com.caseybisson.conflux.devices"
    let accessGroup: String

    /// The directory, when this process may use it: a signed app with the
    /// shared access group. Nil built from source or signed ad hoc, where
    /// peers are added by hand.
    public static func forThisApp() -> KeychainDeviceDirectory? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
                as? [String],
              // Prefixed by the team: an ad hoc build's unprefixed group
              // can't reach iCloud Keychain.
              let group = groups.first(where: { $0.hasSuffix("." + Self.group) })
        else { return nil }
        return KeychainDeviceDirectory(accessGroup: group)
    }

    init(accessGroup: String) { self.accessGroup = accessGroup }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }

    private struct Body: Codable {
        var name: String
        var published: Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func devices() throws -> [ListedDevice] {
        var search = query
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        search[kSecReturnAttributes as String] = true
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(search as CFDictionary, &result) {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return []
        case let status:
            throw DirectoryError.keychain(status)
        }
        // A listing that isn't one, from a later version or damaged, is
        // skipped rather than trusted.
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  DeviceIdentity.isEndpointID(account),
                  let data = item[kSecValueData as String] as? Data,
                  let body = try? Self.decoder.decode(Body.self, from: data)
            else { return nil }
            return ListedDevice(endpointID: account, name: body.name, published: body.published)
        }
    }

    public func publish(_ device: ListedDevice) throws {
        let data = try Self.encoder.encode(Body(name: device.name, published: device.published))
        var match = query
        match[kSecAttrAccount as String] = device.endpointID
        var item = match
        item[kSecValueData as String] = data
        // Synced items can't be ThisDeviceOnly. This one is a public key.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "conflux device"
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw DirectoryError.keychain(status) }
        case let status:
            throw DirectoryError.keychain(status)
        }
    }

    public func remove(_ endpointID: String) throws {
        var match = query
        match[kSecAttrAccount as String] = endpointID
        switch SecItemDelete(match as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status:
            throw DirectoryError.keychain(status)
        }
    }
}

enum DirectoryError: Error, CustomStringConvertible {
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .keychain(let status):
            "iCloud Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
        }
    }
}
