import Foundation

/// Keeps the Mac from idle sleep while conflux has work to do, as the iPad
/// keeps its screen awake.
///
/// A Mac left to idle sleep while it serves doesn't stop being asked for
/// work: peers' requests wake it over the network, it starts running them,
/// and it sleeps again in the middle. A night of that is a Mac waking and
/// sleeping every few seconds with a model running each time, which is more
/// than macOS's sleep should be asked to survive. Held, the Mac stays awake
/// with its display off. Closing the lid or choosing Sleep still sleeps it.
public final class IdleSleepHold: @unchecked Sendable {
    private let reason: String
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    public init(reason: String) {
        self.reason = reason
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Whether the hold is on.
    public var isHeld: Bool {
        lock.withLock { activity != nil }
    }

    /// Holds or releases. Holding twice holds once.
    public func set(_ on: Bool) {
        lock.withLock {
            if on, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: reason)
            } else if !on, let held = activity {
                ProcessInfo.processInfo.endActivity(held)
                activity = nil
            }
        }
    }

    /// Whether a node should hold the Mac awake: while it serves, and while
    /// anything is still waiting or running, its own or relayed to a peer,
    /// so a Drain or Pause finishes before the Mac may sleep. A paused or
    /// drained Mac with nothing left to do is its owner's again.
    public static func wanted(running: Bool, intent: OwnerIntent, unfinished: Int) -> Bool {
        running && (intent == .serving || unfinished > 0)
    }
}
