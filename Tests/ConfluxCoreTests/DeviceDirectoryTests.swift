import Foundation
import Testing
@testable import ConfluxCore

private func someID() -> String { DeviceIdentity.ephemeral().endpointID }

@Suite struct DeviceDirectoryTests {
    @Test func listsThisDeviceTheFirstTime() throws {
        let directory = MemoryDeviceDirectory()
        let id = someID()
        #expect(try directory.keepListed(id, name: "Studio", listedBefore: nil) == .listed)
        #expect(try directory.devices().map(\.endpointID) == [id])
        #expect(try directory.devices().first?.name == "Studio")
    }

    @Test func refreshesOnlyWhenOldOrRenamed() throws {
        let id = someID()
        let then = Date(timeIntervalSince1970: 1_000_000)
        let directory = MemoryDeviceDirectory([ListedDevice(endpointID: id, name: "Studio", published: then)])

        let soon = then.addingTimeInterval(ListedDevice.refreshAfter / 2)
        #expect(try directory.keepListed(id, name: "Studio", listedBefore: id, now: soon) == .listed)
        #expect(try directory.devices().first?.published == then)

        let later = then.addingTimeInterval(ListedDevice.refreshAfter + 1)
        #expect(try directory.keepListed(id, name: "Studio", listedBefore: id, now: later) == .listed)
        #expect(try directory.devices().first?.published == later)

        #expect(try directory.keepListed(id, name: "Laptop", listedBefore: id, now: later) == .listed)
        #expect(try directory.devices().first?.name == "Laptop")
    }

    /// Listed before and gone now: another device forgot this one, and it
    /// doesn't put itself back.
    @Test func aForgottenDeviceStaysOut() throws {
        let directory = MemoryDeviceDirectory()
        let id = someID()
        #expect(try directory.keepListed(id, name: "Studio", listedBefore: nil) == .listed)
        try directory.remove(id)
        #expect(try directory.keepListed(id, name: "Studio", listedBefore: id) == .forgotten)
        #expect(try directory.devices().isEmpty)
        // A different key, a different device: it lists itself.
        let other = someID()
        #expect(try directory.keepListed(other, name: "Studio", listedBefore: id) == .listed)
    }

    @Test func othersLeavesOutThisDeviceAndStaleOnes() throws {
        let now = Date()
        let (me, fresh, stale) = (someID(), someID(), someID())
        let directory = MemoryDeviceDirectory([
            ListedDevice(endpointID: me, name: "me", published: now),
            ListedDevice(endpointID: fresh, name: "fresh", published: now.addingTimeInterval(-3600)),
            ListedDevice(endpointID: stale, name: "stale", published: now.addingTimeInterval(-ListedDevice.staleAfter - 1)),
            ListedDevice(endpointID: "not an id", name: "junk", published: now),
        ])
        #expect(try directory.others(than: me, now: now).map(\.endpointID) == [fresh])
    }

    @Test func removingWhatIsntListedIsFine() throws {
        let directory = MemoryDeviceDirectory()
        try directory.remove(someID())
        #expect(try directory.devices().isEmpty)
    }

    @Test func failuresThrow() {
        let directory = MemoryDeviceDirectory()
        directory.failure = MeshFailure(description: "locked")
        #expect(throws: MeshFailure.self) { try directory.devices() }
        #expect(throws: MeshFailure.self) { try directory.keepListed(someID(), name: "x", listedBefore: nil) }
    }

    /// Unsigned, as `swift test` runs, there's no keychain directory: peers
    /// are added by hand.
    @Test func noKeychainDirectoryUnsigned() {
        #expect(KeychainDeviceDirectory.forThisApp() == nil)
    }
}

@Suite struct TrustedPeerTests {
    @Test func handAddedAndListedTogether() {
        let (me, both, byHand, listedOnly) = (someID(), someID(), someID(), someID())
        let peers = TrustedPeer.merge(
            manual: [both, byHand, byHand, me, "junk"],
            listed: [ListedDevice(endpointID: both, name: "Both"), ListedDevice(endpointID: listedOnly, name: "Listed"),
                     ListedDevice(endpointID: me, name: "Me")],
            this: me)
        #expect(peers.map(\.endpointID) == [both, byHand, listedOnly].sorted())
        let found = Dictionary(uniqueKeysWithValues: peers.map { ($0.endpointID, $0) })
        #expect(found[both] == TrustedPeer(endpointID: both, name: "Both", addedByHand: true))
        #expect(found[byHand] == TrustedPeer(endpointID: byHand, addedByHand: true))
        #expect(found[listedOnly] == TrustedPeer(endpointID: listedOnly, name: "Listed"))
        #expect(found[listedOnly]?.listed == true)
        #expect(found[byHand]?.listed == false)
    }

    @Test func savedSettingsWithoutTheDirectoryLoad() throws {
        let old = #"{"port":8090,"requireToken":true,"peers":[]}"#
        let settings = try JSONDecoder().decode(NodeSettings.self, from: Data(old.utf8))
        #expect(settings.iCloudKeychain)
        #expect(settings.listedID == nil)
    }
}
