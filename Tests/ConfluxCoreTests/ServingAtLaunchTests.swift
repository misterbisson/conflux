import ConfluxCore
import Foundation
import Testing

@Suite struct ServingAtLaunchTests {
    /// A defaults domain of its own, emptied when the test ends.
    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ServingAtLaunchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func doesNotStartBeforeItHasServed() {
        withDefaults { defaults in
            #expect(!ServingAtLaunch(defaults).resumes)
        }
    }

    @Test func startsAgainAfterServing() {
        withDefaults { defaults in
            ServingAtLaunch(defaults).record(running: true, intent: .serving)
            #expect(ServingAtLaunch(defaults).resumes)
        }
    }

    @Test func staysStoppedAfterTheOwnerStops() {
        withDefaults { defaults in
            let serving = ServingAtLaunch(defaults)
            serving.record(running: true, intent: .serving)
            serving.record(running: false, intent: .serving)
            #expect(!ServingAtLaunch(defaults).resumes)
        }
    }

    @Test(arguments: [OwnerIntent.draining, .paused])
    func staysStoppedAfterDrainingOrPausing(_ intent: OwnerIntent) {
        withDefaults { defaults in
            let serving = ServingAtLaunch(defaults)
            serving.record(running: true, intent: .serving)
            serving.record(running: true, intent: intent)
            #expect(!ServingAtLaunch(defaults).resumes)
        }
    }

    @Test func startsAgainAfterResuming() {
        withDefaults { defaults in
            let serving = ServingAtLaunch(defaults)
            serving.record(running: true, intent: .paused)
            serving.record(running: true, intent: .serving)
            #expect(ServingAtLaunch(defaults).resumes)
        }
    }
}
