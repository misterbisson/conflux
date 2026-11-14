import Foundation
import Testing
@testable import ConfluxCore

@Suite struct MemoryReliefTests {
    let start = ContinuousClock.now

    func at(_ seconds: Int) -> ContinuousClock.Instant { start + .seconds(seconds) }

    @Test func ridesOutABriefSpike() {
        var relief = MemoryRelief()
        #expect(relief.observe(.critical, at: at(0)) == .none)
        #expect(relief.nextCheck == at(5))
        #expect(relief.observe(.warning, at: at(3)) == .none)
        #expect(relief.nextCheck == nil)
        // Critical again: the grace starts over.
        #expect(relief.observe(.critical, at: at(4)) == .none)
        #expect(relief.observe(.critical, at: at(8)) == .none)
        #expect(!relief.released)
    }

    @Test func releasesAfterTheGraceAndRestoresOnceNormal() {
        var relief = MemoryRelief()
        #expect(relief.observe(.critical, at: at(0)) == .none)
        #expect(relief.observe(.critical, at: at(5)) == .release)
        #expect(relief.released)
        // Released, it waits for normal pressure, however long it stays high.
        #expect(relief.nextCheck == nil)
        #expect(relief.observe(.critical, at: at(30)) == .none)
        #expect(relief.observe(.warning, at: at(40)) == .none)
        #expect(relief.observe(.normal, at: at(50)) == .none)
        #expect(relief.nextCheck == at(110))
        // Warning before the wait is up starts it over.
        #expect(relief.observe(.warning, at: at(100)) == .none)
        #expect(relief.observe(.normal, at: at(120)) == .none)
        #expect(relief.observe(.normal, at: at(179)) == .none)
        #expect(relief.observe(.normal, at: at(180)) == .restore)
        #expect(!relief.released)
        #expect(relief.observe(.normal, at: at(500)) == .none)
    }

    @Test func waitsLongerWhenLoadingBringsPressureBack() {
        var relief = MemoryRelief()
        var now = 0
        /// Critical long enough to release, then normal long enough to
        /// restore: returns how long it waited.
        func cycle() -> Int {
            #expect(relief.observe(.critical, at: at(now)) == .none)
            #expect(relief.observe(.critical, at: at(now + 5)) == .release)
            let wait = Int(relief.wait.components.seconds)
            #expect(relief.observe(.normal, at: at(now + 6)) == .none)
            #expect(relief.observe(.normal, at: at(now + 6 + wait)) == .restore)
            now += 6 + wait + 10
            return wait
        }
        #expect(cycle() == 60)
        #expect(cycle() == 120)
        #expect(cycle() == 240)
        for _ in 0..<5 { _ = cycle() }
        #expect(cycle() == 1800)
        // Long after coming back, the wait starts again from a minute.
        now += 3600
        #expect(cycle() == 60)
    }

    @Test func saysWhatPolicyDoesAboutMemory() {
        var relief = MemoryRelief()
        #expect(relief.action(slots: [1], memory: .normal) == nil)
        // One slot can't be halved.
        #expect(relief.action(slots: [1], memory: .warning) == nil)
        #expect(relief.action(slots: [4], memory: .warning) == "halved")
        #expect(relief.action(slots: [1], memory: .critical) == "paused")
        // Nothing to hold back.
        #expect(relief.action(slots: [0], memory: .critical) == nil)
        _ = relief.observe(.critical, at: at(0))
        _ = relief.observe(.critical, at: at(5))
        #expect(relief.action(slots: [0], memory: .normal) == "unloaded")
    }

    @Test func labelsThePressure() {
        #expect(MemoryStatus(pressure: .normal).label == "Normal")
        #expect(MemoryStatus(pressure: .critical, action: "unloaded").level == 2)
    }
}
