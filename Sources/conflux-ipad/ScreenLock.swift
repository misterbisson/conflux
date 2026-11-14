import LocalAuthentication
import SwiftUI

/// Locking conflux's screen, so an iPad serving on a stand can be left where
/// others can reach it. Locked, it shows how it's serving and nothing that
/// changes anything, until its owner unlocks it with the iPad's passcode,
/// Face ID or Touch ID.
///
/// It locks conflux, not the iPad: iPadOS's own gestures still leave the
/// app, and leaving it stops serving. Guided Access keeps the iPad in
/// conflux too (docs/running.md, "On an iPad").
enum ScreenLock {
    /// Whether this iPad can check that it's its owner, which needs a
    /// passcode, and which way it checks first.
    static func biometry() -> LABiometryType? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        return context.biometryType
    }

    /// How far the screen moves from where it was, at most, each way.
    static let reach: CGFloat = 12
    /// How often it moves, a point or two at a time.
    static let step: TimeInterval = 10

    /// Where everything sits at a time, so nothing stays on the same pixels
    /// for hours, against burn-in on OLED screens. A slow path that wanders
    /// over a square `reach` each way of centre, sideways every 7 minutes
    /// and up and down every 11, so it comes back to where it started only
    /// after 77, and moves less than two points each step. Too slow to see.
    static func drift(at date: Date) -> CGSize {
        let t = date.timeIntervalSinceReferenceDate
        return CGSize(width: reach * sin(2 * .pi * t / 420), height: reach * sin(2 * .pi * t / 660))
    }

    /// Asks for Face ID, Touch ID or the passcode. True once one passes.
    static func unlock() async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Unlock conflux to change what it serves.")
        } catch let error as LAError where error.code == .passcodeNotSet {
            // The passcode was turned off after it locked, which takes the
            // passcode. With none, nothing can unlock it, and conflux would
            // stay locked until it was deleted.
            return true
        } catch {
            return false
        }
    }
}

/// What a locked conflux shows: how it's serving, read from across a room,
/// and one button, to unlock.
struct LockedView<Status: View>: View {
    let status: Status
    let unlocked: () -> Void
    @State private var asking = false
    @State private var biometry = ScreenLock.biometry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder status: () -> Status, unlocked: @escaping () -> Void) {
        self.status = status()
        self.unlocked = unlocked
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: ScreenLock.step)) { context in
            let drift = ScreenLock.drift(at: context.date)
            content
                .offset(drift)
                .animation(reduceMotion ? nil : .linear(duration: ScreenLock.step), value: drift)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        // Dark while locked, whatever iPadOS is set to: an iPad left serving
        // through the night lights the room less, and on an OLED screen black
        // is pixels turned off. The whole window, status bar included,
        // follows. Unlocked, it's iPadOS's again.
        .preferredColorScheme(.dark)
        // What never changes, the labels and the state, is drawn dimmer
        // (StatusHeadline, StatusFigures, ResourceTile), as Apple's
        // always-on screens do.
        .environment(\.isLuminanceReduced, true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Label("conflux is locked", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: unlock) {
                    Label("Unlock", systemImage: unlockSymbol)
                }
                // Not prominent: a bright button in one place all night is
                // what burns in.
                .buttonStyle(.bordered)
                .disabled(asking)
            }
            status
                // Nothing in it answers a touch, not even a chart's
                // selection: the button above is the only control.
                .allowsHitTesting(false)
        }
    }

    private var unlockSymbol: String {
        switch biometry {
        case .faceID?: "faceid"
        case .touchID?: "touchid"
        case .opticID?: "opticid"
        default: "lock.open"
        }
    }

    private func unlock() {
        asking = true
        Task {
            let passed = await ScreenLock.unlock()
            asking = false
            if passed { unlocked() }
        }
    }
}
