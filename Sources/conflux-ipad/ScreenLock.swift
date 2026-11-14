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

    init(@ViewBuilder status: () -> Status, unlocked: @escaping () -> Void) {
        self.status = status()
        self.unlocked = unlocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Label("conflux is locked", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: unlock) {
                    Label("Unlock", systemImage: unlockSymbol)
                }
                .buttonStyle(.borderedProminent)
                .disabled(asking)
            }
            status
                // Nothing in it answers a touch, not even a chart's
                // selection: the button above is the only control.
                .allowsHitTesting(false)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        // Dark while locked, whatever iPadOS is set to: an iPad left serving
        // through the night lights the room less, and the whole window,
        // status bar included, follows. Unlocked, it's iPadOS's again.
        .preferredColorScheme(.dark)
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
