import ConfluxCore
import ConfluxUI
import SwiftUI
import WebKit

struct ProbeView: View {
    @State private var probe = Probe()
    @State private var server = Server()
    @State private var newPeer = ""
    @State private var peerProblem: String?
    @State private var model: URL?
    @State private var projector: URL?
    @State private var slots = 1
    @State private var contextPerSlot = 4096
    /// What Stop serving would cut off, while it asks.
    @State private var stopping: String?
    /// Whether the document picker is open.
    @State private var choosing = false
    /// The copy Delete would delete, while it asks.
    @State private var deleting: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                serving
                choice
                modelFiles
                mesh
                pair
                device
                results
                Section("About") {
                    LabeledContent("Version") {
                        Text(AppVersion.current).textSelection(.enabled)
                    }
                    NavigationLink("Acknowledgements") { CreditsView().navigationTitle("Acknowledgements") }
                }
            }
            .navigationTitle("conflux")
            .refreshable { probe.reload() }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.gguf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await probe.choose(urls) }
            case .failure(let error): probe.files.problem = "Couldn't open Files: \(error.localizedDescription)"
            }
        }
        // Open in conflux, from the share button in Safari's downloads or the
        // Files app.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await probe.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Models are copied in while the app is in the background.
            if phase == .active { probe.reload() }
            server.setForeground(phase == .active)
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

    @AppStorage("activityMetric") private var metric = ActivityMetric.requests
    @AppStorage("activityRange") private var range = ActivityRange.hour

    /// The iPad's side of things on the chart's span: memory left before
    /// iPadOS ends conflux, heat, and power, which pauses it when unplugged.
    private var resources: some View {
        HStack(alignment: .top, spacing: 20) {
            ResourceTile("Memory left", value: Memory.gigabytes(Memory.available)) {
                Sparkline(server.memoryLeft.bins(range), color: .purple, ceiling: Double(probe.limitAtLaunch))
            }
            ResourceTile("Heat", value: Thermal.label.capitalized) {
                LevelBand(server.heat.bins(range), colors: thermalColors)
            }
            ResourceTile("Power", value: server.charging ? "Charging" : "On battery") {
                LevelBand(server.power.bins(range), colors: [.green, .orange])
            }
        }
    }

    /// Read from across a room: what this iPad is doing, and how much.
    private var serving: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    StatusHeadline(headline, color: headlineColor, detail: headlineDetail)
                    if server.running {
                        // Now; how it's gone is below.
                        let connected = server.peers.filter { $0.path != .none }.count
                        StatusFigures([
                            ("\(server.host?.active ?? 0) of \(server.host?.capacity ?? 0)", "busy"),
                            ("\(connected)", connected == 1 ? "Mac connected" : "Macs connected"),
                        ])
                        ActivityPanel(series: [ActivitySeries(id: ConfluxNode.localHostID, name: "This iPad",
                                                              minutes: server.activity)],
                                      typicalSeconds: server.host?.typicalSeconds, metric: $metric, range: $range)
                        resources
                    }
                }
                .padding(.vertical, 8)
            }
            if server.running {
                Button("Stop serving", role: .destructive, action: askToStop)
                    .confirmationDialog("Stop serving?",
                                        isPresented: Binding(get: { stopping != nil },
                                                             set: { if !$0 { stopping = nil } }),
                                        titleVisibility: .visible, presenting: stopping) { _ in
                        Button("Stop serving", role: .destructive) { server.stop() }
                    } message: { warning in
                        Text(warning)
                    }
            }
            if let problem = server.problem {
                Text(problem).foregroundStyle(.red)
            }
        } footer: {
            Text("This iPad serves its model to your Macs' conflux gateways over iroh. It runs no gateway of its "
                + "own, and clients send it nothing directly.")
        }
    }

    /// Stops at once when no request is running here. Otherwise it asks
    /// first. An iPad runs no gateway, so nothing waits here.
    private func askToStop() {
        if let warning = stopWarning(running: server.host?.active ?? 0, waiting: 0) {
            stopping = warning
        } else {
            server.stop()
        }
    }

    private var headline: String {
        guard server.running else { return "Not serving" }
        guard let host = server.host else { return "Starting" }
        if server.held != nil, case .paused = host.state { return "Paused" }
        return host.state.label
    }

    private var headlineDetail: String? {
        guard server.running else { return "Choose a model below, and serve it to your Macs." }
        if let held = server.held { return held }
        switch server.host?.state {
        case .starting(let why)?, .failed(let why)?, .paused(let why)?: return why
        default: break
        }
        if let model = server.host?.model?.id { return model }
        return nil
    }

    private var headlineColor: Color {
        guard server.running, let state = server.host?.state else { return .secondary }
        return state.color
    }

    /// The Macs this iPad serves, how each is doing, and how they're found.
    /// Pairing by hand, the fallback, has its own section.
    private var mesh: some View {
        Section {
            if let problem = server.meshProblem {
                Text("No Mac can reach this iPad: \(problem)").foregroundStyle(.red)
            }
            if let problem = server.directoryProblem {
                Text("Couldn't read iCloud Keychain: \(problem)").foregroundStyle(.red)
            }
            if let notice = server.directoryNotice {
                Text(notice).foregroundStyle(.orange)
            }
            if server.trusted.isEmpty {
                Text(server.directory != nil && server.settings.iCloudKeychain
                     ? "No Mac yet. Your Macs appear here once they're signed in to this Apple Account and have "
                        + "opened conflux, which can take a minute. Pair one by hand below."
                     : "No Mac yet. Pair one by hand below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(server.trusted) { peer in
                macRow(peer)
            }
            if server.directory != nil {
                Toggle(isOn: Binding(get: { server.settings.iCloudKeychain },
                                     set: { server.setICloudKeychain($0) })) {
                    Text("Find my Macs through iCloud Keychain")
                    Text("Macs signed in to this Apple Account, with iCloud Keychain on and conflux open, find "
                        + "this iPad, and it finds them.")
                }
            }
        } header: {
            Text("Your Macs")
        } footer: {
            Text("Your Macs send this iPad work while it serves."
                + (server.running ? " Changes here take effect the next time it serves." : ""))
        }
    }

    /// Who, and how it's connected.
    private func macRow(_ peer: TrustedPeer) -> some View {
        let path = server.peers.first { $0.endpointID == peer.endpointID }?.path
        let connected = path.map { $0 != .none } ?? false
        return HStack(alignment: .firstTextBaseline) {
            Circle().fill(server.running ? (connected ? Color.green : .orange) : .gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name ?? DeviceIdentity.short(peer.endpointID) + "…")
                    .font(peer.name == nil ? .body.monospaced() : .body)
                    .lineLimit(1).truncationMode(.middle)
                Text(peer.listed ? (peer.addedByHand ? "From iCloud Keychain, and added by hand"
                                                     : "From iCloud Keychain")
                                 : "Added by hand")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if server.running {
                Text(connected ? path?.label ?? "" : "not connected").foregroundStyle(.secondary)
            }
            if peer.addedByHand {
                Button("Remove", role: .destructive) { server.removePeer(peer.endpointID) }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// The fallback: for a Mac on another Apple Account, or a build from
    /// source. Each side gives the other its ID.
    private var pair: some View {
        Section {
            if let id = server.endpointID {
                LabeledContent("This iPad's ID") {
                    HStack {
                        Text(DeviceIdentity.short(id) + "…").font(.body.monospaced())
                        CopyButton(title: "Copy ID") { UIPasteboard.general.string = id; return true }
                    }
                }
            }
            HStack {
                TextField("The Mac's ID", text: $newPeer, prompt: Text("Paste the Mac's ID"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addPeer)
                Button("Add", action: addPeer)
                    .buttonStyle(.borderless)
                    .disabled(newPeer.isEmpty)
            }
            if let peerProblem {
                Text(peerProblem).foregroundStyle(.red)
            }
        } header: {
            Text("Pair by hand")
        } footer: {
            Text((server.directory != nil
                  ? "For a Mac on another Apple Account, or without iCloud Keychain. "
                  : "This build can't use iCloud Keychain, so this is how Macs pair. ")
                + "Copy this iPad's ID into the Mac's conflux window, under Pair by hand, and paste the Mac's ID "
                + "here. Each has to add the other.")
        }
    }

    private func addPeer() {
        peerProblem = server.addPeer(newPeer)
        if peerProblem == nil { newPeer = "" }
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
                Text("No model yet. Add one under Model files.")
                    .foregroundStyle(.secondary)
            } else {
                Group {
                    Picker("Model", selection: $model) {
                        ForEach(probe.models, id: \.self) { url in
                            Text(probe.label(url)).tag(Optional(url))
                        }
                    }
                    Picker("Projector", selection: $projector) {
                        Text("None, text only").tag(URL?.none)
                        ForEach(probe.projectors, id: \.self) { url in
                            Text(probe.label(url)).tag(Optional(url))
                        }
                    }
                    StepperRow("Slots", value: $slots, in: 1...4)
                    Picker("Context per slot", selection: $contextPerSlot) {
                        ForEach(ModelConfig.choices(ModelConfig.contextSizes, including: contextPerSlot),
                                id: \.self) {
                            Text("\($0.formatted()) tokens").tag($0)
                        }
                    }
                }
                .disabled(server.running || probe.running)
                // Left enabled while serving: it applies at once.
                Toggle(isOn: Binding(get: { server.settings.servesOnBattery },
                                     set: { server.setServesOnBattery($0) })) {
                    Text("Serve on battery")
                    Text("Otherwise it serves only while charging, and pauses when unplugged.")
                }
                Button {
                    guard let model else { return }
                    server.start(model: model, projector: projector, slots: slots, contextPerSlot: contextPerSlot)
                } label: {
                    Text("Serve this model to my Macs")
                }
                .disabled(server.running || probe.running || model == nil)
                Button {
                    guard let model else { return }
                    Task { await probe.check(model: model, projector: projector, slots: slots,
                                             contextPerSlot: contextPerSlot) }
                } label: {
                    if probe.running {
                        HStack { ProgressView(); Text(probe.status ?? "Checking…") }
                    } else {
                        Text("Check whether it fits")
                    }
                }
                .disabled(server.running || probe.running || model == nil)
                if server.running {
                    Text("Stop serving to change these.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if probe.models.first.map(Probe.included) == true {
                    Text("The starter model is included with conflux. Add others under Model files.")
                }
                Text("Slots are how many requests this iPad runs at once, and each one takes memory for its "
                    + "context. More slots don't always mean more speed.")
                Text("Keep conflux open while it serves: in the background iPadOS suspends it, and the Macs send "
                    + "their work elsewhere. A check loads the model alone and records the memory it took. If "
                    + "iPadOS ends it, the next launch records the model as killed: too big for this iPad, or for "
                    + "these slots.")
            }
        }
    }

    /// The models added to the starter model, and the ways to add one.
    private var modelFiles: some View {
        Section {
            let added = (probe.models + probe.projectors).filter { !Probe.included($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            ForEach(added, id: \.self) { url in
                fileRow(url)
            }
            // Kept, and listed again once the drive is connected.
            ForEach(probe.files.unavailable) { file in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Text("not connected").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { probe.remove(file) }
                        .buttonStyle(.borderless)
                }
            }
            if let copy = probe.files.copying {
                if let fraction = copy.fraction {
                    ProgressView(value: fraction) {
                        Text("Copying \(copy.name) into conflux…")
                    } currentValueLabel: {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                } else {
                    HStack { ProgressView(); Text("Downloading \(copy.name) from iCloud…") }
                }
                Button("Stop copying", role: .destructive) { probe.files.cancel() }
            }
            if let problem = probe.files.problem {
                Text(problem).foregroundStyle(.red)
            }
            Button("Choose from Files…") {
                // A file on a drive connected again is listed, not chosen twice.
                probe.reload()
                choosing = true
            }
        } header: {
            Text("Model files")
        } footer: {
            Text("Choose a GGUF model in Files, with its projector if it has one, which has \"mmproj\" in its "
                + "name. A model on this iPad or on a drive is used where it is. One in iCloud Drive is copied "
                + "in, since iCloud can remove the iPad's copy of a file. Sharing a model to conflux, from "
                + "Safari's downloads or the Files app, copies it in too. Keep conflux open while it copies. "
                + "From a Mac, select the iPad in Finder, open the Files tab, and drag the files onto conflux.")
        }
        .confirmationDialog("Delete \(deleting?.lastPathComponent ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { url in
            Button("Delete", role: .destructive) { probe.remove(url) }
        } message: { _ in
            Text("This deletes conflux's copy of the file. It can't be undone.")
        }
    }

    /// Where a model is, and how to remove it: a file used in place is
    /// forgotten and stays where it is, and a copy is deleted.
    private func fileRow(_ url: URL) -> some View {
        let inPlace = probe.files.isInPlace(url)
        // Not while it's loaded.
        let inUse = (server.running || probe.running) && (url == model || url == projector)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(Memory.gigabytes(Probe.size(url))) · "
                    + (inPlace ? "used where it is, in \(url.deletingLastPathComponent().lastPathComponent)"
                               : "copied into conflux"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(inPlace ? "Remove" : "Delete", role: .destructive) {
                if inPlace { probe.remove(url) } else { deleting = url }
            }
            .buttonStyle(.borderless)
            .disabled(inUse)
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
