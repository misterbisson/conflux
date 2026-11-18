import ConfluxCore
import ConfluxUI
import SwiftUI

/// The window's tabs, under the status that stays above them: this Mac's
/// models, the devices it shares them with, and the gateway its clients use.
enum WindowTab: String, CaseIterable, Identifiable {
    case models, mesh, gateway

    var id: Self { self }

    var title: String {
        switch self {
        case .models: "Models"
        case .mesh: "Mesh"
        case .gateway: "Gateway"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("windowTab") private var tab = WindowTab.models

    var body: some View {
        VStack(spacing: 0) {
            status
            // One form for every tab, so the activity at its top keeps its
            // state, such as the model it shows, from tab to tab.
            Form {
                activity
                switch tab {
                case .models:
                    modelSection
                    appleSection
                case .mesh:
                    meshSection
                    pairSection
                case .gateway:
                    gatewaySection
                    appsSection
                    requestsSection
                }
            }
            .formStyle(.grouped)
        }
        .padding(.bottom, 8)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $tab) {
                    ForEach(WindowTab.allCases) { tab in
                        tabLabel(tab).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    /// A tab's name, marked when something in it needs looking at, since
    /// it can't be seen from another tab.
    func tabLabel(_ tab: WindowTab) -> Text {
        needsAttention(tab) ? Text("\(tab.title) \(Image(systemName: "exclamationmark.circle"))") : Text(tab.title)
    }

    func needsAttention(_ tab: WindowTab) -> Bool {
        switch tab {
        case .models: !model.fileProblems.isEmpty || (model.running && model.slotProblem != nil)
        case .mesh: model.meshProblem != nil || model.directoryProblem != nil || model.directoryNotice != nil
        case .gateway: false
        }
    }

    // MARK: Status

    /// Read from across a room, above every tab: what this Mac is doing,
    /// how much, and the controls for it.
    var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeadline(stateLabel, color: color, detail: stateDetail) { controls }
            if model.running {
                // Now; how it's gone is in the chart. Waiting has its own tile.
                let own = [model.host, model.appleHost].compactMap { $0 }
                let connected = model.peers.filter { $0.path != .none }.count
                StatusFigures([
                    ("\(own.reduce(0) { $0 + $1.active }) of \(own.reduce(0) { $0 + $1.capacity })", "busy here"),
                    ("\(connected)", connected == 1 ? "peer connected" : "peers connected"),
                    ("\(Int((model.snapshot?.perHour ?? 0).rounded()))", "per hour"),
                    (model.snapshot?.utilization.map(percent) ?? "–", "utilization"),
                ])
                .help("""
                    Requests this Mac's gateway completed in the last ten minutes, scaled to an hour, and the \
                    share of slot time spent running requests on every host in that time.
                    """)
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// At the top of every tab: how it's gone, by host, and the Mac's side
    /// of things over the same span.
    @ViewBuilder var activity: some View {
        if model.running {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ActivityPanel(series: model.activitySeries, typicalSeconds: model.host?.typicalSeconds,
                                  tailSeconds: model.host?.requestSeconds?.p95, metric: $metric, range: $range)
                    resources
                }
                .padding(.vertical, 8)
            }
        }
    }

    @AppStorage("activityMetric") private var metric = ActivityMetric.requests
    @AppStorage("activityRange") private var range = ActivityRange.hour

    /// The Mac's side of things on the chart's span: work waiting at the
    /// gateway, the model's memory, the Mac's memory pressure, and heat.
    var resources: some View {
        HStack(alignment: .top, spacing: 16) {
            ResourceTile("Waiting", value: "\(model.snapshot?.queued ?? 0)") {
                Sparkline(model.waiting.bins(range), color: .blue, ceiling: 4)
            }
            // Against all the Mac's memory: how much of it the model takes.
            let installed = ProcessInfo.processInfo.physicalMemory
            ResourceTile("conflux's memory",
                         value: ProcessMemory.gigabytes(UInt64(model.memory.latest ?? 0))
                            + " of \(installed / 1_073_741_824) GB") {
                Sparkline(model.memory.bins(range), color: .purple, ceiling: Double(installed))
            }
            if let status = model.memoryStatus {
                MemoryPressureTile(status, bins: model.pressure.bins(range))
            }
            HeatTile(model.heatStatus, bins: model.heat.bins(range), setCoolDown: model.setCoolDown)
        }
    }

    /// Requests running and waiting when Stop was clicked, while it asks.
    @State private var stopping: (running: Int, waiting: Int)?

    @ViewBuilder var controls: some View {
        if model.running {
            if model.intent == .serving {
                Button("Drain") { model.setIntent(.draining) }
                    .help("Finish what's running and waiting, here and on peers, and take nothing new")
                Button("Pause") { model.setIntent(.paused) }
                    .help("Take nothing new on this Mac's models until you resume")
            } else {
                Button("Resume") { model.setIntent(.serving) }
                    .help("Take new requests again")
            }
            Button("Stop", action: askToStop)
                .help("Stop the gateway and this Mac's models, and leave the mesh. Requests running or waiting are cut off.")
                .padding(.leading, 12)
                .confirmationDialog("Stop conflux?",
                                    isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                                    presenting: stopping) { _ in
                    Button("Stop", role: .destructive) { model.stop() }
                    if model.intent == .serving {
                        Button("Drain") { model.setIntent(.draining) }
                    }
                } message: { work in
                    Text(stopMessage(running: work.running, waiting: work.waiting))
                }
        } else {
            Button("Start") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
    }

    /// Stops at once when no request is running or waiting at this gateway,
    /// on any host. Otherwise it asks first.
    func askToStop() {
        let running = model.snapshot?.hosts.reduce(0) { $0 + $1.active } ?? 0
        let waiting = model.snapshot?.queued ?? 0
        if running + waiting == 0 {
            model.stop()
        } else {
            stopping = (running, waiting)
        }
    }

    func stopMessage(running: Int, waiting: Int) -> String {
        let drain = model.intent == .serving
            ? " Drain instead to finish what's running and waiting, here and on peers, and take nothing new."
            : ""
        return (stopWarning(running: running, waiting: waiting) ?? "") + drain
    }

    /// The host the headline is about: this Mac's model, unless it serves
    /// no slots, then Apple's.
    var headlineHost: HostSnapshot? {
        model.servesNoSlots ? model.appleHost : model.host ?? model.appleHost
    }

    /// Requests clients sent this Mac's gateway that it still runs or
    /// holds while it drains, on any host, or nil when it isn't draining.
    var drainingRequests: Int? {
        guard let snapshot = model.snapshot, snapshot.draining else { return nil }
        return snapshot.clientRequests
    }

    /// The headline's state: the headline host's, except while the gateway
    /// drains, which isn't done until what clients sent it is.
    var headlineState: HostState? {
        if let left = drainingRequests {
            if left > 0 { return .draining }
            if headlineHost == nil { return .paused("drained") }
        }
        return headlineHost?.state
    }

    var stateLabel: String {
        guard model.running else { return "Stopped" }
        return headlineState?.label ?? "Gateway only"
    }

    /// Why it's in the state it's in, or else what it serves.
    var stateDetail: String? {
        guard model.running else { return "Start to open the gateway, serve this Mac's models and join the mesh." }
        if let left = drainingRequests, left > 0 {
            return "Finishing \(left) \(left == 1 ? "request" : "requests") clients sent here, on any host"
        }
        guard let state = headlineHost else {
            if let detail = headlineState?.detail { return detail }
            return model.servesNoSlots ? "This Mac's model serves no slots: requests go to peers." : nil
        }
        return state.state.detail ?? state.model?.id
    }

    var color: Color {
        guard model.running, let state = headlineState else { return .secondary }
        return state.color
    }

    // MARK: Model

    /// A model file, run by llama.cpp in this process. Off, the section
    /// folds to its switch, as Apple's model's does, and keeps the files and
    /// settings for when it's on again.
    @ViewBuilder var modelSection: some View {
        Section("Custom Model") {
            Toggle("Serve a custom model", isOn: Binding(get: { model.settings.servesModelFile },
                                                         set: { turn(.custom, on: $0) }))
            if model.settings.servesModelFile {
                Group { modelFiles }.disabled(model.running)
                if let served = model.host?.model, model.running {
                    LabeledContent("Fingerprint") {
                        Text(served.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                slotsRow
                slotNotes
                if let host = model.host, model.running {
                    HostRow(host, title: "Requests", hardware: true)
                }
                Group { modelOptions }.disabled(model.running)
                slotsHelp
                if let id = model.modelFileID {
                    ModelLabelsRows(modelID: id, readsImages: model.modelFileReadsImages,
                                    contextTokens: host.contextPerSlot, labels: labelsBinding(id))
                }
                if model.running {
                    Text("Stop conflux to change the rest.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("""
                    A GGUF model file, run by llama.cpp in conflux's own process: the starter model included \
                    with conflux, or one you choose. Off, this Mac serves only Apple's model, when that's on, \
                    and its gateway still uses peers' models.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(turningOff?.title ?? "", isPresented: Binding(get: { turningOff != nil },
                                                                         set: { if !$0 { turningOff = nil } }),
                            presenting: turningOff) { change in
            Button(change.finish) { set(change.model, on: false, cancelling: false) }
            Button(change.stopNow, role: .destructive) { set(change.model, on: false, cancelling: true) }
            Button("Keep Serving", role: .cancel) {}
        } message: { change in
            Text(change.message)
        }
    }

    /// A model turned off while requests run on it, while it asks what to
    /// do with them.
    @State private var turningOff: TurningOff?

    /// Turns a model on or off, at once while conflux runs. Off with
    /// requests running on it asks first whether they finish there, as
    /// cutting slots does.
    func turn(_ which: TurningOff.Model, on: Bool) {
        let running = which == .custom ? model.runningHere : model.appleHost?.active ?? 0
        if !on, model.running, running > 0 {
            turningOff = TurningOff(which, running: running)
        } else {
            set(which, on: on, cancelling: false)
        }
    }

    func set(_ which: TurningOff.Model, on: Bool, cancelling: Bool) {
        switch which {
        case .custom: model.setServesModelFile(on, cancelling: cancelling)
        case .apple: model.setAppleModel(on, cancelling: cancelling)
        }
    }

    @ViewBuilder var modelFiles: some View {
        if model.servesStarter {
            LabeledContent("Model") {
                HStack {
                    Text("Starter model, included").lineLimit(1)
                    Button("Choose…") { model.choose(projector: false) }
                }
            }
            Text("""
                \(StarterModel.modelFile), with its projector: small, reads text and images, and answers \
                poorly. Enough to see a client work through conflux. Choose a model to serve a real one.
                """)
                .font(.caption).foregroundStyle(.secondary)
        } else {
            path("Model", model.settings.host?.model, projector: false)
            path("Projector", model.settings.host?.projector, projector: true)
            ForEach(model.fileProblems, id: \.self) { problem in
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if model.settings.host?.projector != nil {
                Button("Remove projector (text only)") { model.settings.host?.projector = nil }
            }
            if model.starter != nil {
                Button("Use the starter model") { model.useStarter() }
            }
        }
    }

    /// The model's slots, changed at once while conflux runs. Fewer slots
    /// than requests running asks whether to stop the ones left over.
    var slotsRow: some View {
        StepperRow("Slots", value: Binding(get: { host.slots }, set: setSlots), in: 0...32)
            .confirmationDialog(shrinking.map { $0.to == 0 ? "Serve no slots on this Mac?" : "Use \($0.to) \($0.to == 1 ? "slot" : "slots")?" } ?? "",
                                isPresented: Binding(get: { shrinking != nil }, set: { if !$0 { shrinking = nil } }),
                                presenting: shrinking) { change in
                let them = change.cut == 1 ? "It" : "Them"
                Button("Let \(them) Finish") { model.setSlots(change.to) }
                Button("Stop \(them) Now", role: .destructive) { model.setSlots(change.to, cancelling: true) }
                Button("Keep \(host.slots) \(host.slots == 1 ? "Slot" : "Slots")", role: .cancel) {}
            } message: { change in
                Text(Self.shrinkMessage(cut: change.cut))
            }
    }

    /// Under the slots while conflux runs: slots that haven't gone yet,
    /// or didn't fit.
    @ViewBuilder var slotNotes: some View {
        if let host = model.host, model.running {
            let wanted = model.settings.host?.slots ?? host.slots
            let finishing = host.active - wanted
            if finishing > 0 {
                Text("\(finishing) \(finishing == 1 ? "request is" : "requests are") finishing in slots being removed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if host.capacity < host.slots {
                Text("Running \(host.capacity) of \(host.slots) slots: the rest didn't fit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.slotProblem {
                Text("Running \(host.slots) of \(wanted) slots: \(problem).")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    static func shrinkMessage(cut: Int) -> String {
        cut == 1
            ? "A request is running in a slot that goes. It can finish there first, or stop now and go to another host with a free slot; with none, its client hears to try again shortly."
            : "\(cut) requests are running in slots that go. They can finish there first, or stop now and go to other hosts with free slots; with none, their clients hear to try again shortly."
    }

    /// Fewer slots than requests running, and what to do with the ones left
    /// over, while it asks.
    @State private var shrinking: (to: Int, cut: Int)?

    func setSlots(_ slots: Int) {
        let cut = model.running && slots < host.slots ? model.runningHere - slots : 0
        if cut > 0 {
            shrinking = (slots, cut)
        } else {
            model.setSlots(slots)
        }
    }

    @ViewBuilder var modelOptions: some View {
        Picker("Context per slot", selection: binding(\.contextPerSlot)) {
            ForEach(ModelConfig.choices(ModelConfig.contextSizes, including: host.contextPerSlot), id: \.self) {
                Text("\($0.formatted()) tokens").tag($0)
            }
        }
        Picker("Largest image side", selection: binding(\.maxImageDimension)) {
            ForEach(ModelConfig.choices(ModelConfig.imageSides, including: host.maxImageDimension), id: \.self) {
                Text("\($0.formatted()) px").tag($0)
            }
        }
        Toggle("Check the model reads its input before serving", isOn: binding(\.selfCheck))
        if model.settings.host?.projector != nil {
            TextField("Fewest tokens per image", value: binding(\.imageMinTokens), format: .number.grouping(.never),
                      prompt: Text("the model's own setting"))
            Text("Some models read small images badly with fewer tokens. Qwen-VL models want 1024.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var slotsHelp: some View {
        Text("""
            Slots are how many requests this Mac runs at once, and each one takes memory for its context. \
            More slots don't always mean more speed. If the Mac runs short of memory and swaps to disk, use \
            fewer slots or less context. Slots change while conflux runs.
            """)
            .font(.caption).foregroundStyle(.secondary)
        if model.servesNoSlots {
            Text("""
                With no slots, this Mac runs no requests itself and doesn't load the model: its gateway sends \
                every request to peers. Peers can still copy the model.
                """)
                .font(.caption).foregroundStyle(.secondary)
            if model.trusted.isEmpty && !model.settings.appleModel.enabled {
                Text("With no peers, nothing will answer requests.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Apple's model

    @ViewBuilder var appleSection: some View {
        Section("Apple's model") {
            Toggle("Serve Apple's on-device model", isOn: Binding(get: { model.settings.appleModel.enabled },
                                                                  set: { turn(.apple, on: $0) }))
            if model.settings.appleModel.enabled {
                if let apple = model.appleHost, model.running {
                    LabeledContent("State") {
                        HStack {
                            Circle().fill(apple.state.color).frame(width: 8, height: 8)
                            Text(apple.state.label)
                        }
                    }
                    if let detail = apple.state.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Slots", value: "\(apple.active) busy of \(apple.capacity)")
                    HostRow(apple, title: "Requests", hardware: false)
                }
                appleSlotsRow
                ModelLabelsRows(modelID: AppleModelHost.modelID, readsImages: true, contextTokens: nil,
                                labels: labelsBinding(AppleModelHost.modelID))
            }
            Text("""
                The model Apple Intelligence uses, served as \(AppleModelHost.modelID): text and images, in a system \
                process, so it takes none of conflux's memory. It needs Apple Intelligence turned on. It declines \
                some content and takes only short requests; those go to another host when there is one.
                """)
                .font(.caption).foregroundStyle(.secondary)
            if model.settings.appleModel.enabled {
                Text("Its slots change while conflux runs.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Apple's model's slots, changed at once while conflux runs, as the
    /// custom model's are.
    var appleSlotsRow: some View {
        let slots = model.settings.appleModel.slots
        return StepperRow("Slots", value: Binding(get: { slots }, set: setAppleSlots), in: 1...8)
            .confirmationDialog(appleShrinking.map { "Use \($0.to) \($0.to == 1 ? "slot" : "slots") for Apple's model?" } ?? "",
                                isPresented: Binding(get: { appleShrinking != nil }, set: { if !$0 { appleShrinking = nil } }),
                                presenting: appleShrinking) { change in
                let them = change.cut == 1 ? "It" : "Them"
                Button("Let \(them) Finish") { model.setAppleSlots(change.to) }
                Button("Stop \(them) Now", role: .destructive) { model.setAppleSlots(change.to, cancelling: true) }
                Button("Keep \(slots) \(slots == 1 ? "Slot" : "Slots")", role: .cancel) {}
            } message: { change in
                Text(Self.shrinkMessage(cut: change.cut))
            }
    }

    /// Fewer slots for Apple's model than requests running on it, and what
    /// to do with the ones left over, while it asks.
    @State private var appleShrinking: (to: Int, cut: Int)?

    func setAppleSlots(_ slots: Int) {
        let running = model.appleHost?.active ?? 0
        let cut = model.running && slots < model.settings.appleModel.slots ? running - slots : 0
        if cut > 0 {
            appleShrinking = (slots, cut)
        } else {
            model.setAppleSlots(slots)
        }
    }

    var host: ModelConfig { model.settings.host ?? ModelConfig(model: "") }

    func labelsBinding(_ modelID: String) -> Binding<ModelLabels> {
        Binding(get: { model.labels(for: modelID) }, set: { model.setLabels($0, forModel: modelID) })
    }

    func binding<T>(_ path: WritableKeyPath<ModelConfig, T>) -> Binding<T> {
        Binding(get: { host[keyPath: path] },
                set: { value in
                    var updated = host
                    updated[keyPath: path] = value
                    model.settings.host = updated
                })
    }

    func path(_ label: String, _ value: String?, projector: Bool) -> some View {
        LabeledContent(label) {
            HStack {
                Text(value.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { model.choose(projector: projector) }
            }
        }
    }

    // MARK: Mesh

    @State private var newPeer = ""
    @State private var peerProblem: String?
    @State private var forgetting: TrustedPeer?

    /// The devices this Mac shares models with, how each is doing, and how
    /// they're found. Pairing by hand, the fallback, has its own section.
    @ViewBuilder var meshSection: some View {
        Section {
            if let problem = model.meshProblem {
                Text("No device can reach this Mac: \(problem)").foregroundStyle(.red)
            }
            if let problem = model.directoryProblem {
                Text("Couldn't read iCloud Keychain: \(problem)").foregroundStyle(.red)
            }
            if let notice = model.directoryNotice {
                Text(notice).foregroundStyle(.orange)
            }
            if model.trusted.isEmpty {
                Text(model.directory != nil && model.settings.iCloudKeychain
                     ? "No other device yet. Your Macs and iPads appear here once they're signed in to this Apple "
                        + "Account and have opened conflux, which can take a minute. Pair one by hand below."
                     : "No other device yet. Pair one by hand below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.trusted) { peer in
                peerRow(peer)
            }
            if model.running {
                ForEach(otherHosts) { host in
                    HostRow(host, title: model.hostName(host.id), hardware: true)
                }
            }
            if model.refused > 0 {
                LabeledContent("Refused", value: "\(model.refused) connections from devices that aren't peers")
            }
            if model.directory != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Find my Macs through iCloud Keychain",
                           isOn: Binding(get: { model.settings.iCloudKeychain },
                                         set: { model.setICloudKeychain($0) }))
                        .disabled(model.running)
                    Text("Macs and iPads signed in to this Apple Account, with iCloud Keychain on and conflux "
                        + "open, find each other."
                        + (model.running ? " Stop conflux to change this." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mesh")
        } footer: {
            Text("Devices in the mesh use each other's models, and send each other work.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "this device")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { peer in
            Button("Forget", role: .destructive) { model.forget(peer.endpointID) }
        } message: { _ in
            Text("It's removed from iCloud Keychain on every device, and none of them trusts it. If conflux is running there, it stays out until it's turned on there again.")
        }
    }

    /// The fallback: for a device on another Apple Account, or a build from
    /// source. Each side gives the other its ID.
    @ViewBuilder var pairSection: some View {
        Section {
            if let id = model.endpointID {
                LabeledContent("This Mac's ID") {
                    HStack {
                        Text(DeviceIdentity.short(id) + "…").font(.body.monospaced())
                            .help(id)
                        CopyButton(title: "Copy ID") { model.copy(id); return true }
                    }
                }
            }
            LabeledContent("The other device's ID") {
                HStack {
                    TextField("The other device's ID", text: $newPeer, prompt: Text("paste it here"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .onSubmit(addPeer)
                    Button("Add", action: addPeer).disabled(newPeer.isEmpty)
                }
            }
            .disabled(model.running)
            if !model.running, let peerProblem {
                Text(peerProblem).font(.caption).foregroundStyle(.red)
            }
            Text(pairCaption).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Pair by hand")
        }
    }

    var pairCaption: String {
        let how = "Copy this Mac's ID into the other device's conflux, under Pair by hand, and add its ID here. "
            + "Each has to add the other."
        let lock = model.running ? " Stop conflux to add or remove one." : ""
        return model.directory != nil
            ? "For a device on another Apple Account, or without iCloud Keychain. \(how)\(lock)"
            : "Built from source, conflux can't use iCloud Keychain, so this is how devices pair. \(how)\(lock)"
    }

    func addPeer() {
        peerProblem = model.addPeer(newPeer)
        if peerProblem == nil { newPeer = "" }
    }

    /// One line for who and how it's doing, one for the detail.
    @ViewBuilder func peerRow(_ peer: TrustedPeer) -> some View {
        let id = peer.endpointID
        let status = model.peers.first { $0.endpointID == id }
        let host = status.flatMap(model.peerHost)
        let connected = status.map { $0.path != .none } ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(peerColor(running: model.running, connected: connected, host: host))
                    .frame(width: 8, height: 8)
                if let name = peer.name {
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                Text(DeviceIdentity.short(id) + "…").font(.body.monospaced())
                    .foregroundStyle(peer.name == nil ? .primary : .secondary).help(id)
                Spacer()
                if model.running {
                    Text(connected ? host?.state.label ?? "Connected" : "Not connected")
                        .foregroundStyle(.secondary)
                }
                if peer.addedByHand {
                    Button("Remove") { model.removePeer(id) }
                        .disabled(model.running)
                }
                if peer.listed {
                    Button("Forget…") { forgetting = peer }
                }
            }
            // Each host it serves: Apple's model alongside its model file,
            // say. Its slots and its work count them all, the way busy here
            // counts this Mac's.
            let hosts = status.map(model.peerHosts) ?? []
            let live = connected ? hosts : []
            let models = live.compactMap(\.model?.id)
            let capacity = live.reduce(0) { $0 + $1.capacity }
            let parts = [source(of: peer),
                         model.running ? status.map(\.path.label) : nil,
                         host?.hardware?.summary,
                         models.isEmpty ? nil : models.joined(separator: " and "),
                         capacity > 0 ? "\(live.reduce(0) { $0 + $1.active }) busy of \(capacity)" : nil]
                .compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if model.running, let detail = host?.state.detail {
                Text(detail).font(.caption).foregroundStyle(connected ? .secondary : Color.orange)
            }
            // How each of its hosts has done, as this Mac's gateway sees it.
            if model.running {
                ForEach(hosts) { host in
                    HostRow(host, title: host.model?.id ?? model.hostName(host.id), hardware: false)
                        .padding(.leading, 16)
                }
            }
        }
    }

    /// Hosts this Mac's gateway has sent work to that belong to no peer in
    /// the list, such as one that was removed. Each keeps its counts.
    var otherHosts: [HostSnapshot] {
        let listed = Set(model.trusted.flatMap { peer in
            model.peers.first { $0.endpointID == peer.endpointID }?.hostIDs ?? []
        })
        return (model.snapshot?.hosts ?? []).filter { $0.id.hasPrefix("peer-") && !listed.contains($0.id) }
    }

    /// Grey while stopped, orange while it can't be reached, and otherwise
    /// the colour of its host's state.
    func peerColor(running: Bool, connected: Bool, host: HostSnapshot?) -> Color {
        guard running else { return .gray }
        guard connected, let host else { return .orange }
        return host.state.color
    }

    func source(of peer: TrustedPeer) -> String {
        switch (peer.listed, peer.addedByHand) {
        case (true, true): "From iCloud Keychain, and added by hand"
        case (true, false): "From iCloud Keychain"
        default: "Added by hand"
        }
    }

    // MARK: Requests

    /// The USE method's three for the whole mesh, as this Mac's gateway sees
    /// it: utilization, in the status above every tab; saturation (work
    /// waiting, how long it waits, idle-with-work); and errors, with what
    /// was declined and hedged. Each host's own are beside it: this Mac's
    /// under Models, peers' under Mesh.
    @ViewBuilder var requestsSection: some View {
        if model.running, let snapshot = model.snapshot {
            Section {
                LabeledContent("Completed", value: "\(snapshot.completed)")
                    .help("Requests this gateway completed, on any host")
                LabeledContent("Waiting", value: Counts.waiting(queued: snapshot.queued, wait: snapshot.waitSeconds))
                    .help("Requests waiting here for a slot now, and how long requests waited in the last ten minutes")
                LabeledContent("Idle while work waited", value: Counts.seconds(snapshot.idleWithWorkSeconds))
                    .help("Time a host had a free slot while work it could run waited here: it should stay near zero")
                LabeledContent("Host failures", value: Counts.describe(snapshot.failures))
                    .help("What went wrong with requests sent to hosts. Most were retried on another host.")
                LabeledContent("Answered busy · unavailable", value: "\(snapshot.busy) · \(snapshot.unavailable)")
                    .help("Answers of 429, no slot in time, and 503, hosts failed or none up")
                if snapshot.declined.total > 0 {
                    LabeledContent("Declined", value: Counts.describe(snapshot.declined, rerouted: snapshot.rerouted))
                        .help("Requests a model declined that another might take, the slot time they took, "
                              + "and how many another host then answered")
                }
                if snapshot.hedged > 0 {
                    LabeledContent("Hedged", value: "\(snapshot.hedged), \(snapshot.hedgeWins) answered first")
                        .help("Copies of straggling requests sent to an idle host at the end of a batch")
                }
            } header: {
                Text("Requests")
            } footer: {
                Text("""
                    What became of the requests clients sent this gateway, on any host. Declined requests are \
                    ones a model refused that another might take, such as content Apple's model declines: \
                    they're sent on to another host, but the time they took is spent. Each host's own counts \
                    are beside it, under Models and Mesh.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Gateway

    @State private var tokenProblem: String?

    @ViewBuilder var gatewaySection: some View {
        Section("Gateway") {
            LabeledContent("Port") {
                TextField("Port", value: $model.settings.port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            .disabled(model.running)
            if let port = model.port {
                let url = "http://127.0.0.1:\(port)/v1"
                LabeledContent("Endpoint") {
                    HStack {
                        Text(url).font(.body.monospaced()).textSelection(.enabled)
                        CopyButton(title: "Copy") { model.copy(url); return true }
                    }
                }
            }
            Toggle("Require the token", isOn: $model.settings.requireToken)
                .disabled(model.running)
            if model.settings.requireToken {
                LabeledContent("Token") {
                    HStack {
                        CopyButton(title: "Copy", copy: copyToken)
                        Button("New token") { model.rotateToken() }
                    }
                }
                if let tokenProblem {
                    Text(tokenProblem).font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("Any process on this Mac can use the gateway without a token.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.running {
                Text("Stop conflux to change the port or the token setting.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The apps with tokens of their own, each with Revoke. Hidden until one
    /// has paired.
    @ViewBuilder var appsSection: some View {
        if !model.paired.isEmpty {
            Section {
                ForEach(model.paired) { app in
                    HStack {
                        AppIcon(bundleID: app.bundleID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(Self.pairedDetail(app)).font(.caption).foregroundStyle(.secondary)
                        }
                        .help("\(app.bundleID), " + (app.teamID.map { "team \($0)" } ?? "no Team ID"))
                        Spacer()
                        Button("Revoke") { model.revoke(app) }
                            .help("Refuse this app's next request. It has to ask again to use your models.")
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text(model.settings.requireToken
                     ? "Apps you let use your models, each with a token of its own."
                     : "Apps you let use your models, each with a token of its own. While the token isn't "
                       + "required, any process on this Mac can use the gateway, these apps included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func pairedDetail(_ app: PairedApp) -> String {
        let paired = "Paired " + app.paired.formatted(date: .abbreviated, time: .omitted)
        guard let used = app.lastUsed else { return paired + ", not used yet" }
        return paired + ", last used " + used.formatted(.relative(presentation: .named))
    }

    private func copyToken() -> Bool {
        guard let token = model.token else {
            tokenProblem = "Couldn't read the token."
            return false
        }
        tokenProblem = nil
        model.copy(token)
        return true
    }
}

/// An app's icon, by its bundle ID, or a generic one when it can't be found.
struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
    }

    var icon: NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
