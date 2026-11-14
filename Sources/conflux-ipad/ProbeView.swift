import ConfluxCore
import ConfluxUI
import SwiftUI
import WebKit

struct ProbeView: View {
    @State private var probe = Probe()
    @State private var server: Server
    /// The models the Macs serve, and getting one here.
    @State private var macModels: MacModels
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

    init() {
        let server = Server()
        _server = State(initialValue: server)
        _macModels = State(initialValue: MacModels(server: server))
    }

    var body: some View {
        NavigationStack {
            Form {
                serving
                choice
                appleModel
                modelFiles
                fromMacs
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
            .confirmationDialog(turningOff?.title ?? "",
                                isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } }),
                                titleVisibility: .visible, presenting: turningOff) { change in
                Button(change.finish) { set(change.model, on: false, cancelling: false) }
                Button(change.stopNow, role: .destructive) { set(change.model, on: false, cancelling: true) }
                Button("Keep Serving", role: .cancel) {}
            } message: { change in
                Text(change.message)
            }
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
            // The mesh alone runs while conflux is open and not serving, to
            // reach the Macs. In the background iPadOS suspends it, and a
            // pull stops, to resume on return.
            switch phase {
            case .active: server.startMesh()
            case .background:
                macModels.pause("conflux left the foreground")
                server.stopMesh()
            default: break
            }
        }
        .onChange(of: server.meshUp) { _, up in
            if up { macModels.startRefreshing() } else { macModels.stopRefreshing() }
        }
        // A Mac connected: ask what it serves now, not at the next look.
        .onChange(of: server.peers.filter { $0.path != .none }.map(\.endpointID)) { _, _ in
            if server.meshUp { macModels.refresh() }
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
            macModels.arrived = { [probe] in probe.reload() }
            server.startMesh()
            if server.meshUp { macModels.startRefreshing() }
        }
    }

    /// The projector that goes with the chosen model: the starter model's
    /// with it, and otherwise the one whose header says it fits, if there's
    /// one (Projectors.suggestion). A projector made for another model fails
    /// to load, so with no fit there's no suggestion.
    private var suggestedProjector: URL? {
        guard let model else { return nil }
        if Probe.included(model) { return probe.projectors.first(where: Probe.included) }
        return Projectors.suggestion(for: GGUFFile(model), among: probe.projectors.map { GGUFFile($0) })
    }

    /// What's wrong with the chosen projector for the chosen model, from
    /// their headers.
    private var pairProblems: [String] {
        Projectors.problems(model: model.map { GGUFFile($0) }, projector: projector.map { GGUFFile($0) })
    }

    /// The models measured on iPads so far. A link only: conflux fetches
    /// nothing from the internet.
    private static let measurements =
        URL(string: "https://github.com/misterbisson/conflux/blob/main/docs/measurements.md")!

    private var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// What iPadOS lets conflux use, of the iPad's memory, and how large a
    /// model likely loads, with room for its context and for iPadOS
    /// (ModelFit). What iPadOS allows can be nearly all of the iPad's
    /// memory, more than it can spare once a model is loaded.
    private var allowance: String {
        let allowed = probe.limitAtLaunch
        let largest = ModelFit.largestModel(allowed: allowed, physicalMemory: physicalMemory)
        let lets = "iPadOS lets conflux use about \(Memory.roughly(allowed)) of this iPad's "
            + "\(Memory.roughly(physicalMemory))"
        guard largest > 0 else { return lets + ", which is likely too little for any model but the smallest." }
        return lets + ". Leaving room for iPadOS, models up to about \(Memory.roughly(largest)), with their "
            + "projectors, will likely load."
    }

    /// The chosen model's memory: what a check of these files with these
    /// settings measured, or, before one has, an estimate. A hint, never a
    /// block: Serve and Check stay enabled either way.
    @ViewBuilder private var fit: some View {
        if let model {
            let checked = probe.measured(model: model, projector: projector, slots: slots,
                                         contextPerSlot: contextPerSlot)
            switch checked?.outcome {
            case .passed?:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fits: checked on this iPad").foregroundStyle(.green)
                    Text(measuredDetail(checked))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .killed?:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Too big: checked on this iPad").foregroundStyle(.red)
                    Text("iPadOS ended conflux while it was loading or running these files with these slots "
                        + "and context. Try fewer slots, less context, or a smaller model.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .failed?, nil:
                estimate(model, failed: checked?.detail)
            }
        }
    }

    /// What a check that passed measured once the model loaded.
    private func measuredDetail(_ result: ProbeResult?) -> String {
        switch (result?.footprintAfterLoad, result?.availableAfterLoad) {
        case let (footprint?, left?):
            "Once it loaded, conflux took \(Memory.roughly(footprint)), and \(Memory.roughly(left)) was left."
        case let (footprint?, nil):
            "Once it loaded, conflux took \(Memory.roughly(footprint))."
        default:
            "It loaded and answered."
        }
    }

    /// The estimate for the chosen model, from its files and its header.
    private func estimate(_ model: URL, failed: String?) -> some View {
        let metadata = try? GGUFFile(model).metadata.get()
        let estimate = ModelFit(model: metadata, modelBytes: Probe.size(model),
                                projectorBytes: projector.map(Probe.size), slots: slots,
                                contextPerSlot: contextPerSlot)
        let allowed = probe.limitAtLaunch
        let fits = estimate.likelyFits(allowed: allowed, physicalMemory: physicalMemory)
        var detail = "\(Memory.roughly(estimate.weights)) of files"
        if let context = estimate.context {
            detail += ", \(Memory.roughly(context)) of context for \(slots) × \(contextPerSlot.formatted()) tokens"
        }
        detail += ", and \(Memory.roughly(estimate.working)) of room to work in. conflux counts on about "
            + "\(Memory.roughly(ModelFit.usable(allowed: allowed, physicalMemory: physicalMemory))) of the "
            + "\(Memory.roughly(allowed)) iPadOS allows, keeping the rest of the iPad's "
            + "\(Memory.roughly(physicalMemory)) for iPadOS and what the estimate can't see."
        return VStack(alignment: .leading, spacing: 4) {
            Text(fits ? "Likely fits: about \(Memory.roughly(estimate.total))"
                      : "Likely too big: about \(Memory.roughly(estimate.total))")
                .foregroundStyle(fits ? Color.primary : Color.orange)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            if estimate.context == nil {
                Text("The model's header doesn't say how much memory its context takes, so the estimate "
                    + "leaves it out.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let trained = estimate.trainedContext {
                Text("The model was trained to read up to \(trained.formatted()) tokens. More context per slot "
                    + "takes memory, and may not help.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(failed.map { "The last check of these files with these settings failed: \($0). This is an "
                    + "estimate; a check measures it." }
                 ?? "This is an estimate, not a limit. A check measures it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @AppStorage("activityMetric") private var metric = ActivityMetric.requests
    @AppStorage("activityRange") private var range = ActivityRange.hour

    /// The iPad's side of things on the chart's span: memory left before
    /// iPadOS ends conflux, the whole iPad's memory pressure, which can end
    /// it sooner, heat, and power, which pauses it when unplugged.
    private var resources: some View {
        HStack(alignment: .top, spacing: 20) {
            ResourceTile("Memory left", value: Memory.gigabytes(Memory.available)) {
                Sparkline(server.memoryLeft.bins(range), color: .purple, ceiling: Double(probe.limitAtLaunch))
            }
            if let status = server.memoryStatus {
                MemoryPressureTile(status, bins: server.pressure.bins(range))
            }
            HeatTile(server.heatStatus, bins: server.heat.bins(range), setCoolDown: server.setCoolDown)
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
                        let own = server.ownHosts
                        StatusFigures([
                            ("\(own.reduce(0) { $0 + $1.active }) of \(own.reduce(0) { $0 + $1.capacity })", "busy"),
                            ("\(connected)", connected == 1 ? "Mac connected" : "Macs connected"),
                        ])
                        ActivityPanel(series: activitySeries, typicalSeconds: primaryHost?.typicalSeconds,
                                      metric: $metric, range: $range)
                        resources
                    }
                }
                .padding(.vertical, 8)
            }
            if !server.running {
                Button {
                    server.start(model: model, projector: projector, slots: slots, contextPerSlot: contextPerSlot)
                } label: {
                    Text(serveLabel)
                }
                // Starting would cut off the Mac a model is coming from.
                .disabled(probe.running || macModels.active || !canServe)
            }
            // Left enabled while serving: it applies at once.
            Toggle(isOn: Binding(get: { server.settings.servesOnBattery },
                                 set: { server.setServesOnBattery($0) })) {
                Text("Serve on battery")
                Text("Otherwise it serves only while charging, and pauses when unplugged.")
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
            Text("This iPad serves its models to your Macs' conflux gateways over iroh. It runs no gateway of its "
                + "own, and clients send it nothing directly. Keep conflux open while it serves: in the background "
                + "iPadOS suspends it, and the Macs send their work elsewhere.")
        }
    }

    /// Each of this iPad's hosts that has served, the model file's first.
    private var activitySeries: [ActivitySeries] {
        let both = server.activity[ConfluxNode.localHostID] != nil && server.activity[ConfluxNode.appleHostID] != nil
        return [(ConfluxNode.localHostID, both ? "Model file" : "This iPad", server.host),
                (ConfluxNode.appleHostID, "Apple's model", server.appleHost)].compactMap { id, name, host in
            server.activity[id].map {
                ActivitySeries(id: id, name: name, minutes: $0, model: host?.model?.id,
                               typicalSeconds: host?.typicalSeconds)
            }
        }
    }

    /// Whether either model is turned on.
    private var servesAny: Bool { server.settings.modelFile || server.settings.appleModel }

    /// The host the headline speaks for: the model file's, or Apple's model
    /// when it serves alone.
    private var primaryHost: HostSnapshot? { server.host ?? server.appleHost }

    /// Stops at once when no request is running here. Otherwise it asks
    /// first. An iPad runs no gateway, so nothing waits here.
    private func askToStop() {
        if let warning = stopWarning(running: server.ownHosts.reduce(0) { $0 + $1.active }, waiting: 0) {
            stopping = warning
        } else {
            server.stop()
        }
    }

    private var headline: String {
        guard server.running else { return "Not serving" }
        guard servesAny else { return "Serving nothing" }
        guard let host = primaryHost else { return "Starting" }
        if server.held != nil, case .paused = host.state { return "Paused" }
        return host.state.label
    }

    private var headlineDetail: String? {
        guard server.running else { return "Choose what to serve below, and serve it to your Macs." }
        guard servesAny else { return "Turn on the custom model or Apple's model below." }
        if let held = server.held { return held }
        switch primaryHost?.state {
        case .starting(let why)?, .failed(let why)?, .paused(let why)?: return why
        default: break
        }
        let models = server.ownHosts.compactMap { $0.model?.id }
        return models.isEmpty ? nil : models.joined(separator: " and ")
    }

    private var headlineColor: Color {
        guard server.running, let state = primaryHost?.state else { return .secondary }
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
            Text("Your Macs send this iPad work while it serves. While conflux is open and not serving, it stays "
                + "connected to them, to get a model from one."
                + (server.running ? " Changes here take effect the next time it serves." : ""))
        }
    }

    /// Who, and how it's connected.
    private func macRow(_ peer: TrustedPeer) -> some View {
        let path = server.peers.first { $0.endpointID == peer.endpointID }?.path
        let connected = path.map { $0 != .none } ?? false
        return HStack(alignment: .firstTextBaseline) {
            Circle().fill(server.meshUp ? (connected ? Color.green : .orange) : .gray)
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
            if server.meshUp {
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
            if let chip = HardwareInfo.current.chip {
                LabeledContent("Chip", value: chip)
            }
            if let cores = HardwareInfo.current.cpuCores {
                LabeledContent("CPU", value: cores)
            }
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

    /// A model turned off while requests run on it, while it asks what to
    /// do with them.
    @State private var turningOff: TurningOff?

    /// Turns a model on or off, at once while serving. Off with requests
    /// running on it asks first whether they finish there.
    private func turn(_ which: TurningOff.Model, on: Bool) {
        let running = (which == .custom ? server.host : server.appleHost)?.active ?? 0
        if !on, server.running, running > 0 {
            turningOff = TurningOff(which, running: running)
        } else {
            set(which, on: on, cancelling: false)
        }
    }

    private func set(_ which: TurningOff.Model, on: Bool, cancelling: Bool) {
        switch which {
        case .custom:
            server.setModelFile(on, model: model, projector: projector, slots: slots, contextPerSlot: contextPerSlot,
                                cancelling: cancelling)
        case .apple:
            server.setAppleModel(on, cancelling: cancelling)
        }
    }

    /// What Serve would serve: the custom model, Apple's, or both.
    private var serveLabel: String {
        switch (server.settings.modelFile, server.settings.appleModel) {
        case (true, true): "Serve this model and Apple's to my Macs"
        case (false, true): "Serve Apple's model to my Macs"
        default: "Serve this model to my Macs"
        }
    }

    private var canServe: Bool {
        (server.settings.modelFile && model != nil) || server.settings.appleModel
    }

    /// Apple's on-device model, served beside the model file or alone. It
    /// runs in a system process, outside conflux's memory limit.
    private var appleModel: some View {
        Section {
            // Read once a second: Apple Intelligence can be turned on, or
            // its model finish downloading, while conflux is open.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let unavailable = AppleModelHost.unavailableReason
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { server.settings.appleModel },
                                         set: { turn(.apple, on: $0) })) {
                        Text("Serve Apple's on-device model")
                        if let unavailable, !server.running {
                            Text(unavailable.prefix(1).uppercased() + unavailable.dropFirst() + ".")
                        }
                    }
                    if server.running, server.settings.appleModel {
                        if let apple = server.appleHost {
                            LabeledContent("State") {
                                HStack {
                                    Circle().fill(apple.state.color).frame(width: 8, height: 8)
                                    Text(apple.state.label)
                                }
                            }
                            if let detail = apple.state.detail {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            LabeledContent("Slots", value: "\(apple.active) busy of \(apple.capacity)")
                            if let typical = apple.typicalSeconds {
                                LabeledContent("Typical request", value: String(format: "%.1f s", typical))
                            }
                        } else {
                            Text("Starting").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Apple's model")
        } footer: {
            Text("The model Apple Intelligence uses, served to your Macs as \(AppleModelHost.modelID): text and "
                + "images. It runs in a system process, so it takes none of the memory iPadOS lets conflux use, "
                + "and it serves beside the custom model or alone. It needs Apple Intelligence turned on in "
                + "Settings. It declines some content and takes only short requests; those go to another host.")
        }
    }

    /// A model file, run by llama.cpp in conflux. Off, the section folds to
    /// its switch, as Apple's model's does, and keeps the choices for when
    /// it's on again.
    private var choice: some View {
        Section {
            Toggle(isOn: Binding(get: { server.settings.modelFile }, set: { turn(.custom, on: $0) })) {
                Text("Serve a custom model")
            }
            if !server.settings.modelFile {
                Text("A GGUF model file, run by llama.cpp in conflux: the starter model included with conflux, or "
                    + "one added under Model files. Off, this iPad serves only Apple's model, when that's on.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if probe.models.isEmpty {
                Text("No model yet. Add one under Model files.")
                    .foregroundStyle(.secondary)
            } else {
                Text(allowance).font(.callout)
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
                    ForEach(pairProblems, id: \.self) { problem in
                        Text(problem).foregroundStyle(.red)
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
                fit
                Link(destination: Self.measurements) {
                    Label("Models measured on iPads", systemImage: "arrow.up.right.square")
                }
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
            Text("Custom Model")
        } footer: {
            if server.settings.modelFile {
                VStack(alignment: .leading, spacing: 6) {
                    if probe.models.first.map(Probe.included) == true {
                        Text("The starter model is included with conflux. Add others under Model files.")
                    }
                    Text("Slots are how many requests this iPad runs at once, and each one takes memory for its "
                        + "context. More slots don't always mean more speed.")
                    Text("A check loads the model alone and records the memory it took. If iPadOS ends it, the "
                        + "next launch records the model as killed: too big for this iPad, or for these slots.")
                }
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
            // Kept, and listed again once the drive is connected, or the
            // file is back.
            ForEach(probe.files.unavailable) { file in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Text(file.missing ? "missing" : "not connected")
                            .font(.footnote).foregroundStyle(.secondary)
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
            Text("Choose a GGUF model in Files, with its projector if it has one. conflux reads each file to "
                + "tell projectors from models, and chooses the projector made for the model. A model on this "
                + "iPad or on a drive is used where it is. One in iCloud Drive is copied in, since iCloud can "
                + "remove the iPad's copy of a file. Sharing a model to conflux, from Safari's downloads or the "
                + "Files app, copies it in too. Keep conflux open while it copies. "
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

    /// Each connected Mac's model and projector, and copying them here.
    private var fromMacs: some View {
        Section {
            if let notice = macModels.notice {
                Text(notice).foregroundStyle(.green)
            }
            if let pull = macModels.pull, !shownWithItsMac(pull) {
                // From a Mac that isn't in the mesh now, or whose offer
                // isn't in yet, or has changed.
                pullRow(pull)
            }
            if !server.meshUp {
                Text(server.trusted.isEmpty ? "No Mac yet. Pair one under Your Macs, below."
                                            : "Connecting to your Macs…")
                    .foregroundStyle(.secondary)
            } else if server.peers.isEmpty {
                Text("No Mac yet.").foregroundStyle(.secondary)
            }
            ForEach(server.peers) { peer in
                offerRow(peer)
            }
        } header: {
            Text("Get a model from your Macs")
        } footer: {
            Text("A Mac running conflux offers the model it serves, and its projector, to the devices it trusts. "
                + "conflux copies both here over the mesh, checks each against the Mac's, and keeps them "
                + "together in a folder named for the model, with the Mac's file names, so this iPad serves the "
                + "same model. Nothing comes from the internet. Keep conflux open while it copies: the screen "
                + "stays awake, and if it stops, Resume carries on where it stopped.")
        }
    }

    /// Whether a pull shows under its Mac's offer: the Mac is in the mesh
    /// and still offers those files.
    private func shownWithItsMac(_ pull: MacModels.Pull) -> Bool {
        server.peers.contains { $0.endpointID == pull.peer } && macModels.offers[pull.peer] == .files(pull.list)
    }

    private func macName(_ endpointID: String) -> String {
        server.trusted.first { $0.endpointID == endpointID }?.name ?? DeviceIdentity.short(endpointID) + "…"
    }

    @ViewBuilder private func offerRow(_ peer: PeerStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(macName(peer.endpointID)).font(.headline)
            switch macModels.offers[peer.endpointID] {
            case nil:
                Text(peer.path == .none ? "Not connected" : "Asking what it serves…")
                    .font(.footnote).foregroundStyle(.secondary)
            case .problem(let why)?:
                Text("Can't say what it serves: \(why)").font(.footnote).foregroundStyle(.secondary)
            case .files(let list)? where list.files.isEmpty:
                Text("Serves no model file.").font(.footnote).foregroundStyle(.secondary)
            case .files(let list)?:
                offer(list, from: peer)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func offer(_ list: PeerFileList, from peer: PeerStatus) -> some View {
        ForEach(list.files) { file in
            Text("\(file.name) · \(Memory.gigabytes(UInt64(file.size)))")
                .lineLimit(1).truncationMode(.middle)
        }
        if list.projector == nil {
            Text("No projector: text only.").font(.footnote).foregroundStyle(.secondary)
        }
        let here = macModels.alreadyHere(list, among: probe.models + probe.projectors)
        let pulling = macModels.pull.map { $0.peer == peer.endpointID && $0.list == list } ?? false
        if here {
            Text("Already on this iPad.").font(.footnote).foregroundStyle(.secondary)
        } else {
            fitLine(list)
            pathLine(list, path: peer.path)
        }
        if pulling, let pull = macModels.pull {
            pullRow(pull)
        } else if !here {
            Button("Get this model") {
                macModels.get(list, from: peer.endpointID, name: macName(peer.endpointID))
            }
            // One at a time: another, stopped, resumes or is discarded first.
            .disabled(macModels.pull != nil || peer.path == .none
                      || (MacModels.freeStorage.map { $0 < list.size } ?? false))
        }
    }

    /// Whether the pair likely fits this iPad's memory, with one slot and a
    /// typical context (ModelFit), and its storage.
    private func fitLine(_ list: PeerFileList) -> some View {
        let largest = ModelFit.largestModel(allowed: probe.limitAtLaunch, physicalMemory: physicalMemory)
        let fits = UInt64(list.size) <= largest
        let free = MacModels.freeStorage
        let room = free.map { $0 >= list.size } ?? true
        return VStack(alignment: .leading, spacing: 2) {
            Text(fits ? "Likely fits this iPad's memory, with one slot."
                      : "Likely too big for this iPad's memory: models up to about \(Memory.roughly(largest)), "
                        + "with their projectors, will likely load.")
                .foregroundStyle(fits ? Color.secondary : Color.orange)
            Text("Takes \(Memory.roughly(UInt64(list.size))) of storage"
                + (free.map { ", and \(Memory.roughly(UInt64(max(0, $0)))) is free." } ?? "."))
                .foregroundStyle(room ? Color.secondary : Color.red)
        }
        .font(.footnote)
    }

    /// Direct, or relayed and slow, with how long it would take.
    @ViewBuilder private func pathLine(_ list: PeerFileList, path: PeerPath) -> some View {
        switch path {
        case .direct:
            Text("Connected directly: about \(MacModels.duration(list.size, at: MacModels.directRate)).")
                .font(.footnote).foregroundStyle(.secondary)
        case .relay:
            Text("Connected through a relay, which is slow: at \(MacModels.rate(MacModels.relayRate)) at best, "
                + "this takes about \(MacModels.duration(list.size, at: MacModels.relayRate)), and could take "
                + "much longer. On the same network as the Mac, with Local Network allowed, it's direct.")
                .font(.footnote).foregroundStyle(.orange)
        case .none:
            Text("Not connected.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// How far it has got, and Stop, Resume or Discard.
    @ViewBuilder private func pullRow(_ pull: MacModels.Pull) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(pull.received), total: Double(max(1, pull.total))) {
                Text("\(pull.list.modelID ?? pull.folder) from \(pull.name)").lineLimit(1).truncationMode(.middle)
            } currentValueLabel: {
                Text(pullDetail(pull))
            }
            switch pull.state {
            case .pulling:
                Button("Stop", role: .destructive) { macModels.stop() }
            case .stopped(let why):
                if let why { Text("Stopped: \(why)").font(.footnote).foregroundStyle(.secondary) }
                HStack {
                    Button("Resume") { macModels.resume() }
                        .disabled(!server.peers.contains { $0.endpointID == pull.peer && $0.path != .none })
                    Spacer()
                    Button("Discard", role: .destructive) { macModels.discard() }
                }
                .buttonStyle(.borderless)
            case .failed(let why):
                Text(why).font(.footnote).foregroundStyle(.red)
                Button("Dismiss") { macModels.discard() }
            }
        }
    }

    private func pullDetail(_ pull: MacModels.Pull) -> String {
        var parts = ["\(Memory.roughly(UInt64(pull.received))) of \(Memory.roughly(UInt64(pull.total)))"]
        if pull.state == .pulling, let rate = pull.progress?.bytesPerSecond, rate > 0 {
            parts.append(MacModels.rate(rate))
            parts.append("about \(MacModels.duration(pull.total - pull.received, at: rate)) left")
        }
        return parts.joined(separator: " · ")
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
                               : Probe.folder(of: url).map { "copied into conflux, in \($0)" } ?? "copied into conflux"))
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
