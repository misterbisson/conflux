import Foundation

/// Whether a model file used in place, through a security-scoped bookmark,
/// can be used now, and if not, whether it's likely to come back.
///
/// The iPad keeps a bookmark to each file chosen in the document picker that
/// it uses where it is (Sources/conflux-ipad/ModelFiles.swift). A bookmark
/// that doesn't resolve is either on a drive that isn't connected, which
/// comes back when the drive does, or to a file that was deleted, or moved
/// somewhere the bookmark can't follow, which doesn't.
///
/// What tells them apart, and how sure each is:
///
/// - **The error doesn't.** Resolving a bookmark to a deleted file, and to a
///   file on a volume that isn't mounted, both fail with `NSCocoaErrorDomain`
///   code 4, `NSFileNoSuchFileError`, "The file doesn't exist." That's what
///   macOS 27 does, for APFS and ExFAT volumes alike; Apple doesn't document
///   the errors, and the iPad can't be tried here. The error is still
///   checked: anything other than "no such file" can't be told apart, and is
///   taken for a drive that isn't connected.
/// - **The volume does.** A bookmark records the volume its file was on, and
///   `URL.resourceValues(forKeys:fromBookmarkData:)` reads them back without
///   resolving it, documented on iOS since 4.0. The volume's UUID
///   (`volumeUUIDStringKey`) is persistent, unlike `volumeIdentifierKey`,
///   which Apple documents as not lasting across restarts. If the volume at
///   the bookmark's volume URL (`volumeURLKey`) has that UUID now, the volume
///   is mounted. A drive that's unplugged has no volume there, or only the
///   folder it was mounted on, which is on another volume with another UUID.
///   `FileManager.mountedVolumeURLs`, which would list the volumes, returns
///   nil on every platform but macOS, as its documentation says.
/// - **The iPad's own storage is always mounted.** A file in On My iPad is on
///   the same volume as conflux's own folders, so a bookmark whose volume
///   UUID is that volume's was to a file on the iPad itself, and if it doesn't
///   resolve, the file is gone. This holds even when the sandbox won't say
///   what's at the bookmark's volume URL.
/// - **A file in the trash isn't there for the person.** A bookmark follows a
///   file moved to the trash, as it follows any move on a volume, so it
///   resolves, to a file that can be read. `FileManager.getRelationship(_:of:
///   in:toItemAt:)` with `.trashDirectory` says whether it's there, as its
///   documentation describes; whether iPadOS counts the Files app's Recently
///   Deleted as the trash isn't documented.
///
/// Where any fact is missing, as when the bookmark doesn't record a volume
/// UUID (some file systems have none), the file is taken for one on a drive
/// that isn't connected, and its bookmark is kept: keeping a bookmark is
/// always safer than losing one.
///
/// Nothing here removes a bookmark, and the app doesn't either: a missing
/// file's is kept, and tried again, until the person removes it. Removing
/// one by itself, after it had been missing for a while, would need the two
/// cases told apart reliably, and they're told apart only as well as the
/// facts above allow: undocumented errors, and a volume layout on iPadOS that
/// can't be tried here. A file can also come back, put back from Recently
/// Deleted, or in another app's storage once that app has it again. A wrong
/// "missing" costs a label; a wrong removal costs the person choosing the
/// file again.
public enum InPlaceFile {
    public enum State: Sendable, Equatable {
        /// Resolved, and readable.
        case available
        /// Can't be reached now, likely because its drive isn't connected,
        /// or for a reason that can't be told. Kept, and tried again.
        case notConnected
        /// Its volume is there and the file isn't: deleted, in the trash, or
        /// moved where the bookmark can't follow.
        case missing
    }

    /// What was learned trying to reach a file.
    public struct Facts: Sendable, Equatable {
        public enum Resolution: Sendable, Equatable {
            /// The bookmark resolved to a file that can be read.
            case readable(inTrash: Bool)
            /// It resolved, to a file that can't be read.
            case unreadable
            /// It didn't resolve.
            case failed(domain: String, code: Int)
        }

        public var resolution: Resolution
        /// The UUID of the volume the file was on, saved in the bookmark.
        public var savedVolume: String?
        /// The UUID of the volume at the bookmark's volume URL now.
        public var volumeNow: String?
        /// The UUID of the volume this app's own folders are on, which is
        /// always mounted while it runs.
        public var ownVolume: String?

        public init(resolution: Resolution, savedVolume: String? = nil, volumeNow: String? = nil,
                    ownVolume: String? = nil) {
            self.resolution = resolution
            self.savedVolume = savedVolume
            self.volumeNow = volumeNow
            self.ownVolume = ownVolume
        }

        /// The facts for a bookmark that didn't resolve: the error, and its
        /// volume, then and now. `own` is a folder of this app's.
        public init(failure: any Error, bookmark: Data, own: URL) {
            let error = failure as NSError
            let saved = URL.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey], fromBookmarkData: bookmark)
            self.init(resolution: .failed(domain: error.domain, code: error.code),
                      savedVolume: saved?.volumeUUIDString,
                      volumeNow: saved?.volume.flatMap { Self.volumeUUID($0) },
                      ownVolume: Self.volumeUUID(own))
        }

        /// The UUID of the volume a file or folder is on now, or nil when
        /// it's not there, or can't be read.
        static func volumeUUID(_ url: URL) -> String? {
            // A new URL, so no value cached from before is read.
            (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        }
    }

    /// The resource values to save in a bookmark, so they can be read back
    /// when it doesn't resolve. Bookmarks record them anyway; asking for them
    /// makes sure.
    public static let bookmarkKeys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey]

    public static func state(_ facts: Facts) -> State {
        switch facts.resolution {
        case .readable(let inTrash):
            return inTrash ? .missing : .available
        case .unreadable:
            // There, but not readable: permission, or a provider that isn't
            // ready. Nothing says it's gone.
            return .notConnected
        case .failed(let domain, let code):
            guard domain == NSCocoaErrorDomain,
                  code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError,
                  let saved = facts.savedVolume
            else { return .notConnected }
            let mounted = saved == facts.volumeNow || saved == facts.ownVolume
            return mounted ? .missing : .notConnected
        }
    }
}
