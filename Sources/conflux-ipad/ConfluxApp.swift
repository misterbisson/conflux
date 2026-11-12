import SwiftUI

/// conflux on iPadOS: a host that serves its model to the Macs' gateways,
/// and a memory probe that checks whether a model fits (docs/plan.md,
/// Phase 3).
@main
struct ConfluxApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}
