import SwiftUI
import WebKit

struct ProbeView: View {
    @State private var probe = Probe()
    @State private var model: URL?
    @State private var projector: URL?
    @State private var slots = 1
    @State private var contextPerSlot = 4096
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This first iPad version doesn't join the mesh yet. It checks whether a model fits: "
                        + "it loads one, makes sure it reads its input, and records the memory that took.")
                        .foregroundStyle(.secondary)
                }
                device
                choice
                results
                Section {
                    NavigationLink("Acknowledgements") { CreditsView().navigationTitle("Acknowledgements") }
                }
            }
            .navigationTitle("conflux")
            .refreshable { probe.reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Models are copied in while the app is in the background.
            if phase == .active { probe.reload() }
        }
        .onChange(of: probe.models) { _, models in
            if model.map({ !models.contains($0) }) ?? true { model = models.first }
        }
        .onChange(of: probe.projectors) { _, projectors in
            if let chosen = projector, !projectors.contains(chosen) { projector = nil }
            if projector == nil { projector = suggestedProjector }
        }
        .onChange(of: model) { _, _ in projector = suggestedProjector }
        .onAppear {
            model = probe.models.first
            projector = suggestedProjector
        }
    }

    /// The projector that goes with the chosen model: the starter model's
    /// with it, and otherwise the one copied in, if there's only one. A
    /// projector made for another model fails to load.
    private var suggestedProjector: URL? {
        guard let model else { return nil }
        let copied = probe.projectors.filter { !Probe.included($0) }
        if Probe.included(model) { return probe.projectors.first(where: Probe.included) }
        return copied.count == 1 ? copied.first : nil
    }

    private var device: some View {
        Section("This iPad") {
            LabeledContent("Model", value: Memory.machine)
            LabeledContent("iPadOS", value: UIDevice.current.systemVersion)
            LabeledContent("Memory", value: Memory.gigabytes(ProcessInfo.processInfo.physicalMemory))
            LabeledContent("Allowed at launch", value: Memory.gigabytes(probe.limitAtLaunch))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 8) {
                    LabeledContent("Available now", value: Memory.gigabytes(Memory.available))
                    LabeledContent("Footprint now", value: Memory.gigabytes(Memory.footprint.now))
                    LabeledContent("Temperature", value: probe.thermal)
                    LabeledContent("Power", value: probe.charging.map { $0 ? "charging" : "on battery" } ?? "unknown")
                }
            }
        }
    }

    private var choice: some View {
        Section {
            if probe.models.isEmpty {
                Text("""
                    Copy a GGUF model here from a Mac: connect the iPad, select it in Finder, open the Files tab, \
                    and drag the file onto conflux. The Files app shows the same folder, under On My iPad. \
                    A vision model's projector goes alongside it, with "mmproj" in its name.
                    """)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $model) {
                    ForEach(probe.models, id: \.self) { url in
                        Text(Probe.label(url)).tag(Optional(url))
                    }
                }
                Picker("Projector", selection: $projector) {
                    Text("None, text only").tag(URL?.none)
                    ForEach(probe.projectors, id: \.self) { url in
                        Text(Probe.label(url)).tag(Optional(url))
                    }
                }
                Stepper("Slots: \(slots)", value: $slots, in: 1...4)
                Picker("Context per slot", selection: $contextPerSlot) {
                    ForEach([2048, 4096, 8192], id: \.self) { Text("\($0) tokens").tag($0) }
                }
                Button {
                    guard let model else { return }
                    Task { await probe.check(model: model, projector: projector, slots: slots,
                                             contextPerSlot: contextPerSlot) }
                } label: {
                    if probe.running {
                        HStack { ProgressView(); Text(probe.status ?? "Checking…") }
                    } else {
                        Text("Check this model")
                    }
                }
                .disabled(probe.running || model == nil)
            }
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if probe.models.first.map(Probe.included) == true {
                    Text("The starter model is included with conflux. To check another, copy it here from a Mac: "
                        + "in Finder, select the iPad, open the Files tab, and drag the file onto conflux. A vision "
                        + "model's projector goes alongside it, with \"mmproj\" in its name.")
                }
                Text("Keep conflux open while it checks. If iPadOS ends it, the next launch records the model as "
                    + "killed: too big for this iPad, or for these slots.")
            }
        }
    }

    private var results: some View {
        Section("Results") {
            if probe.results.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(probe.results.reversed()) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.model).font(.headline)
                        Spacer()
                        Text(result.outcome.rawValue)
                            .foregroundStyle(result.outcome == .passed ? .green : .red)
                    }
                    Text(line(for: result)).font(.footnote).foregroundStyle(.secondary)
                    if let detail = result.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !probe.results.isEmpty {
                ShareLink(item: probe.summary) { Label("Share results", systemImage: "square.and.arrow.up") }
                Button("Clear results", role: .destructive) { probe.clear() }
            }
        }
    }

    private func line(for r: ProbeResult) -> String {
        var parts = ["\(r.slots) × \(r.contextPerSlot)"]
        if let s = r.loadSeconds { parts.append(String(format: "loaded in %.0f s", s)) }
        if let f = r.footprintAfterLoad { parts.append("footprint \(Memory.gigabytes(f))") }
        if let a = r.availableAfterLoad { parts.append("\(Memory.gigabytes(a)) left") }
        if let s = r.requestSeconds {
            let tokens = r.completionTokens.map { String(format: ", %.1f tokens/s", Double($0) / max(s, 0.001)) } ?? ""
            parts.append(String(format: "request %.1f s", s) + tokens)
        }
        return parts.joined(separator: " · ")
    }
}

/// The licences of what the app includes: App/Credits.html, which the Mac
/// app shows in its About window.
struct CreditsView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
