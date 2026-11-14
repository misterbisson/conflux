import ConfluxCore
import Foundation
import SwiftUI

// What the Mac app and the iPad app show the same way: the status at the top
// of the window, the colours of hosts' states, and Copy buttons.

/// What this device is doing, read from across a room: its state in large
/// type, a line on why, and what's around it, such as the Mac's controls.
public struct StatusHeadline<Accessory: View>: View {
    let title: String
    let color: Color
    let detail: String?
    let accessory: Accessory

    public init(_ title: String, color: Color, detail: String?, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.color = color
        self.detail = detail
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: Self.size, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
                accessory
            }
            if let detail {
                Text(detail).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    #if os(macOS)
    static var size: CGFloat { 34 }
    #else
    static var size: CGFloat { 44 }
    #endif
}

extension StatusHeadline where Accessory == EmptyView {
    public init(_ title: String, color: Color, detail: String?) {
        self.init(title, color: color, detail: detail) { EmptyView() }
    }
}

/// A row of figures under the headline: a number, and what it counts.
public struct StatusFigures: View {
    let figures: [(value: String, label: String)]

    public init(_ figures: [(value: String, label: String)]) {
        self.figures = figures
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 32) {
            ForEach(figures.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Text(figures[index].value).font(.title.monospacedDigit().weight(.semibold))
                    Text(figures[index].label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension HostState {
    /// The same colour for a state everywhere it's shown.
    public var color: Color {
        switch self {
        case .ready: .green
        case .busy: .blue
        case .draining, .paused, .starting: .orange
        case .failed, .offline: .red
        }
    }
}

/// How hot this device is, as the system says.
public enum Thermal {
    public static var label: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// What stopping now would cut off: requests running and waiting, said in a
/// sentence or two. Nil when there's nothing.
public func stopWarning(running: Int, waiting: Int) -> String? {
    guard running + waiting > 0 else { return nil }
    let work = switch (running, waiting) {
    case (_, 0): "\(running) \(running == 1 ? "request is" : "requests are") running."
    case (0, _): "\(waiting) \(waiting == 1 ? "request is" : "requests are") waiting."
    default: "\(running) \(running == 1 ? "request is" : "requests are") running and \(waiting) \(waiting == 1 ? "is" : "are") waiting."
    }
    return work + " Stopping cuts \(running + waiting == 1 ? "it" : "them") off."
}

/// A setting stepped up and down, laid out as the pickers around it are: its
/// name on the left, and its value on the right beside the control.
public struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
    }

    public var body: some View {
        LabeledContent(title) {
            HStack {
                // Plain text doesn't dim when disabled, so it's dimmed here,
                // as a picker's value is.
                Text(value.formatted()).monospacedDigit()
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Stepper(title, value: $value, in: range).labelsHidden()
            }
        }
    }
}

/// A button that copies something and says "Copied" for a moment after it has.
public struct CopyButton: View {
    let title: String
    /// Copies, and says whether it did.
    let copy: () -> Bool

    @State private var copied = false
    @State private var copies = 0

    public init(title: String, copy: @escaping () -> Bool) {
        self.title = title
        self.copy = copy
    }

    public var body: some View {
        Button {
            copied = copy()
            copies += 1
        } label: {
            // Both labels take up room, so the button keeps its width.
            ZStack {
                Text(title).opacity(copied ? 0 : 1)
                Text("Copied").opacity(copied ? 1 : 0)
            }
        }
        .accessibilityLabel(copied ? "Copied" : title)
        // Each copy restarts the wait; leaving the window cancels it.
        .task(id: copies) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }
}

/// A host's slots, changed at once while it serves. Fewer slots than
/// requests running asks whether to let the extra ones finish first, or stop
/// them now, the newest first, so their gateways send them to other hosts.
public struct LiveSlotsRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let running: Int
    let apply: (_ slots: Int, _ cancelling: Bool) -> Void

    /// Fewer slots than requests running, and how many are left over, while
    /// it asks.
    @State private var shrinking: (to: Int, cut: Int)?

    /// `running` is the requests running on the host now, none when it
    /// isn't serving. `apply` takes the new slots, and whether to stop the
    /// requests left over.
    public init(_ title: String = "Slots", value: Int, in range: ClosedRange<Int>, running: Int,
                apply: @escaping (_ slots: Int, _ cancelling: Bool) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.running = running
        self.apply = apply
    }

    public var body: some View {
        StepperRow(title, value: Binding(get: { value }, set: change), in: range)
            .confirmationDialog(shrinking.map(Self.question) ?? "",
                                isPresented: Binding(get: { shrinking != nil }, set: { if !$0 { shrinking = nil } }),
                                presenting: shrinking) { change in
                let them = change.cut == 1 ? "It" : "Them"
                Button("Let \(them) Finish") { apply(change.to, false) }
                Button("Stop \(them) Now", role: .destructive) { apply(change.to, true) }
                Button("Keep \(Self.slots(value).capitalized)", role: .cancel) {}
            } message: { change in
                Text(Self.explanation(cut: change.cut))
            }
    }

    private func change(_ slots: Int) {
        let cut = slots < value ? running - slots : 0
        if cut > 0 {
            shrinking = (slots, cut)
        } else {
            apply(slots, false)
        }
    }

    static func slots(_ count: Int) -> String { "\(count) \(count == 1 ? "slot" : "slots")" }

    static func question(_ change: (to: Int, cut: Int)) -> String {
        change.to == 0 ? "Serve no slots?" : "Use \(slots(change.to))?"
    }

    static func explanation(cut: Int) -> String {
        cut == 1
            ? "A request is running in a slot that goes. It can finish there first, or stop now and go to "
                + "another host with a free slot; with none, its client hears to try again shortly."
            : "\(cut) requests are running in slots that go. They can finish there first, or stop now and go "
                + "to other hosts with free slots; with none, their clients hear to try again shortly."
    }
}
