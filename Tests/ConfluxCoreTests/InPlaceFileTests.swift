import Foundation
import Testing
@testable import ConfluxCore

@Suite struct InPlaceFileTests {
    typealias Facts = InPlaceFile.Facts

    static let noSuchFile = Facts.Resolution.failed(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    static let drive = "6F2D0C5E-1B7A-4B8E-9C3D-2A1F0E9D8C7B"
    static let ipad = "0B1C2D3E-4F50-4617-8293-A4B5C6D7E8F9"

    @Test func aReadableFileIsAvailable() {
        #expect(InPlaceFile.state(Facts(resolution: .readable(inTrash: false))) == .available)
    }

    @Test func aFileInTheTrashIsMissing() {
        #expect(InPlaceFile.state(Facts(resolution: .readable(inTrash: true))) == .missing)
    }

    @Test func aFileThatCantBeReadIsNotConnected() {
        #expect(InPlaceFile.state(Facts(resolution: .unreadable, savedVolume: Self.drive, volumeNow: Self.drive))
            == .notConnected)
    }

    @Test func aDriveThatIsntMountedIsNotConnected() {
        // Nothing at the volume's URL now.
        #expect(InPlaceFile.state(Facts(resolution: Self.noSuchFile, savedVolume: Self.drive, volumeNow: nil,
                                        ownVolume: Self.ipad)) == .notConnected)
        // Only the folder it was mounted on, on the iPad's own volume.
        #expect(InPlaceFile.state(Facts(resolution: Self.noSuchFile, savedVolume: Self.drive, volumeNow: Self.ipad,
                                        ownVolume: Self.ipad)) == .notConnected)
    }

    @Test func aFileGoneFromADriveThatsThereIsMissing() {
        #expect(InPlaceFile.state(Facts(resolution: Self.noSuchFile, savedVolume: Self.drive, volumeNow: Self.drive,
                                        ownVolume: Self.ipad)) == .missing)
        let read = Facts.Resolution.failed(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(InPlaceFile.state(Facts(resolution: read, savedVolume: Self.drive, volumeNow: Self.drive))
            == .missing)
    }

    @Test func aFileGoneFromTheIPadIsMissing() {
        // Even when what's at the volume's URL can't be read.
        #expect(InPlaceFile.state(Facts(resolution: Self.noSuchFile, savedVolume: Self.ipad, volumeNow: nil,
                                        ownVolume: Self.ipad)) == .missing)
    }

    @Test func withoutTheSavedVolumeItCantBeTold() {
        #expect(InPlaceFile.state(Facts(resolution: Self.noSuchFile, savedVolume: nil, volumeNow: Self.ipad,
                                        ownVolume: Self.ipad)) == .notConnected)
    }

    @Test func anotherErrorCantBeTold() {
        let permission = Facts.Resolution.failed(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(InPlaceFile.state(Facts(resolution: permission, savedVolume: Self.ipad, volumeNow: Self.ipad,
                                        ownVolume: Self.ipad)) == .notConnected)
        let posix = Facts.Resolution.failed(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(InPlaceFile.state(Facts(resolution: posix, savedVolume: Self.ipad, volumeNow: Self.ipad,
                                        ownVolume: Self.ipad)) == .notConnected)
    }

    /// A real bookmark to a file that's deleted, on a volume that's mounted:
    /// the error, and the volume it records, are what the decision expects.
    @Test func aDeletedFilesBookmarkIsMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "InPlaceFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "model.gguf")
        try Data("GGUF".utf8).write(to: file)
        let bookmark = try file.bookmarkData(options: [], includingResourceValuesForKeys: InPlaceFile.bookmarkKeys,
                                             relativeTo: nil)
        try FileManager.default.removeItem(at: file)

        var stale = false
        let failure = #expect(throws: (any Error).self) {
            _ = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
        }
        let facts = Facts(failure: try #require(failure), bookmark: bookmark, own: folder)
        #expect(facts.resolution == Self.noSuchFile)
        #expect(facts.savedVolume != nil)
        #expect(facts.savedVolume == facts.ownVolume)
        #expect(InPlaceFile.state(facts) == .missing)
    }
}
