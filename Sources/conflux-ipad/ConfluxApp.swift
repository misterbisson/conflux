import SwiftUI

/// conflux on iPadOS. Its first version is a memory probe; it becomes a
/// host in a later one (docs/plan.md, Phase 3).
@main
struct ConfluxApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}
