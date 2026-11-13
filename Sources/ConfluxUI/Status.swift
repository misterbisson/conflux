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
