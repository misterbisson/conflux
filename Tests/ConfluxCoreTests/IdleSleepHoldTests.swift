import ConfluxCore
import Testing

@Suite struct IdleSleepHoldTests {
    @Test func holdsWhileServing() {
        #expect(IdleSleepHold.wanted(running: true, intent: .serving, unfinished: 0))
        #expect(IdleSleepHold.wanted(running: true, intent: .serving, unfinished: 3))
    }

    @Test func letsTheMacSleepWhenStopped() {
        #expect(!IdleSleepHold.wanted(running: false, intent: .serving, unfinished: 0))
        #expect(!IdleSleepHold.wanted(running: false, intent: .serving, unfinished: 2))
    }

    @Test func holdsUntilADrainOrPauseFinishes() {
        for intent in [OwnerIntent.draining, .paused] {
            #expect(IdleSleepHold.wanted(running: true, intent: intent, unfinished: 1))
            #expect(!IdleSleepHold.wanted(running: true, intent: intent, unfinished: 0))
        }
    }

    @Test func holdsOnceAndReleases() {
        let hold = IdleSleepHold(reason: "IdleSleepHoldTests")
        #expect(!hold.isHeld)
        hold.set(true)
        hold.set(true)
        #expect(hold.isHeld)
        hold.set(false)
        #expect(!hold.isHeld)
        hold.set(false)
        #expect(!hold.isHeld)
    }
}
