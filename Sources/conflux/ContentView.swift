import ConfluxCore
import ConfluxUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            status
            modelSection
            appleSection
            meshSection
            pairSection
            monitoringSection
            gatewaySection
            aboutSection
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    // MARK: Status

    /// Read from across a room: what this Mac is doing, and how much.
    @ViewBuilder var status: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                StatusHeadline(stateLabel, color: color, detail: stateDetail) { controls }
                if model.running {
                    // Now; how it's gone is below. Waiting has its own tile.
                    let own = [model.host, model.appleHost].compactMap { $0 }
                    let connected = model.peers.filter { $0.path != .none }.count
                    StatusFigures([
                        ("\(own.reduce(0) { $0 + $1.active }) of \(own.reduce(0) { $0 + $1.capacity })", "busy here"),
                        ("\(connected)", connected == 1 ? "peer connected" : "peers connected"),
                    ])
                    ActivityPanel(series: model.activitySeries, typicalSeconds: model.host?.typicalSeconds,
                                  metric: $metric, range: $range)
                    resources
                }
            }
            .padding(.vertical, 8)
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red)
            }
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
                if let served = host.model {
                    LabeledContent("Fingerprint") {
                        Text(served.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @AppStorage("activityMetric") private var metric = ActivityMetric.requests
    @AppStorage("activityRange") private var range = ActivityRange.hour

    /// The Mac's side of things on the chart's span: work waiting at the
    /// gateway, the model's memory, and heat.
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
            ResourceTile("Heat", value: Thermal.label.capitalized) {
                LevelBand(model.heat.bins(range), colors: thermalColors)
            }
        }
    }

    /// Requests running and waiting when Stop was clicked, while it asks.
    @State private var stopping: (running: Int, waiting: Int)?

    @ViewBuilder var controls: some View {
        if model.running {
            if model.intent == .serving {
                Button("Drain") { model.setIntent(.draining) }
                    .help("Finish what's running and take nothing new")
                Button("Pause") { model.setIntent(.paused) }
                    .help("Take nothing new on this Mac's models until you resume")
            } else {
                Button("Resume") { model.setIntent(.serving) }
                    .help("Take new requests on this Mac's models again")
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
            ? " Drain instead to let this Mac's models finish what they're running and take nothing new."
            : ""
        return (stopWarning(running: running, waiting: waiting) ?? "") + drain
    }

    /// The host the headline is about: this Mac's model, unless it serves
    /// no slots, then Apple's.
    var headlineHost: HostSnapshot? {
        model.servesNoSlots ? model.appleHost : model.host ?? model.appleHost
    }

    var stateLabel: String {
        guard model.running else { return "Stopped" }
        return headlineHost?.state.label ?? "Gateway only"
    }

    /// Why it's in the state it's in, or else what it serves.
    var stateDetail: String? {
        guard model.running else { return "Start to open the gateway, serve this Mac's models and join the mesh." }
        guard let state = headlineHost else {
            return model.servesNoSlots ? "This Mac's model serves no slots: requests go to peers." : nil
        }
        return state.state.detail ?? state.model?.id
    }

    var color: Color {
        guard model.running, let state = headlineHost?.state else { return .secondary }
        return state.color
    }

    // MARK: Model

    @ViewBuilder var modelSection: some View {
        Section("Model") {
            Group { modelFiles }.disabled(model.running)
            slotsRow
            Group { modelOptions }.disabled(model.running)
            slotsHelp
            if model.running {
                Text("Stop conflux to change the rest.").font(.caption).foregroundStyle(.secondary)
            }
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

    /// The model's slots, changed at once while conflux runs.
    var slotsRow: some View {
        LiveSlotsRow(value: host.slots, in: 0...32, running: model.running ? model.runningHere : 0) {
            model.setSlots($0, cancelling: $1)
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
            Toggle("Serve Apple's on-device model too", isOn: $model.settings.appleModel.enabled)
                .disabled(model.running)
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
                    if let typical = apple.typicalSeconds {
                        LabeledContent("Typical request", value: String(format: "%.1f s", typical))
                    }
                }
                LiveSlotsRow(value: model.settings.appleModel.slots, in: 1...8,
                             running: model.running ? model.appleHost?.active ?? 0 : 0) {
                    model.setAppleSlots($0, cancelling: $1)
                }
            }
            Text("""
                The model Apple Intelligence uses, served as \(AppleModelHost.modelID): text and images, in a system \
                process, so it takes none of conflux's memory. It needs Apple Intelligence turned on. It declines \
                some content and takes only short requests; those go to another host when there is one.
                """)
                .font(.caption).foregroundStyle(.secondary)
            if model.running {
                Text("Stop conflux to turn it on or off. Its slots change while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var host: ModelConfig { model.settings.host ?? ModelConfig(model: "") }

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
            let live = connected ? host : nil
            let parts = [source(of: peer),
                         model.running ? status.map(\.path.label) : nil,
                         live?.model?.id,
                         live.flatMap { $0.capacity > 0 ? "\($0.active) busy of \($0.capacity)" : nil },
                         host.flatMap { $0.completed > 0 ? "\($0.completed) completed" : nil }].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if model.running, let detail = host?.state.detail {
                Text(detail).font(.caption).foregroundStyle(connected ? .secondary : Color.orange)
            }
        }
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

    // MARK: Monitoring

    /// Throughput, failures and idle-with-work, for the mesh and each host,
    /// as this Mac's gateway sees them.
    @ViewBuilder var monitoringSection: some View {
        if model.running, let snapshot = model.snapshot {
            Section("Monitoring") {
                LabeledContent("Throughput", value: "\(Int(snapshot.perHour.rounded())) per hour")
                LabeledContent("Completed", value: "\(snapshot.completed)")
                LabeledContent("Idle while work waited", value: Self.seconds(snapshot.idleWithWorkSeconds))
                LabeledContent("Host failures", value: Self.describe(snapshot.failures))
                LabeledContent("Answered busy · unavailable", value: "\(snapshot.busy) · \(snapshot.unavailable)")
                    .help("Answers of 429, no slot in time, and 503, hosts failed or none up")
                if snapshot.hedged > 0 {
                    LabeledContent("Hedged", value: "\(snapshot.hedged), \(snapshot.hedgeWins) answered first")
                        .help("Copies of straggling requests sent to an idle host at the end of a batch")
                }
                ForEach(snapshot.hosts) { host in
                    monitoringRow(host)
                }
                Text("Idle while work waited is time a host had a free slot while work it could run waited here. It should stay near zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func monitoringRow(_ host: HostSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let name = model.peerName(of: host) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else if host.id.hasPrefix("peer-") {
                    Text(host.id.dropFirst("peer-".count) + "…").font(.body.monospaced())
                } else {
                    Text("This Mac")
                }
                Spacer()
                Text("\(Int(host.perHour.rounded())) per hour").monospacedDigit()
            }
            let parts = ["\(host.completed) completed",
                         host.typicalSeconds.map { String(format: "typical %.1f s", $0) },
                         "idle with work \(Self.seconds(host.idleWithWorkSeconds))",
                         host.prefetched > 0 ? "\(host.prefetched) sent ahead" : nil,
                         host.failures.total > 0 ? Self.describe(host.failures) : nil].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : String(format: "%.0f s", value)
    }

    static func describe(_ failures: FailureCounts) -> String {
        guard failures.total > 0 else { return "none" }
        return [(failures.unavailable, "not answering"), (failures.failed, "server error"),
                (failures.busy, "busy"), (failures.deadline, "out of time")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
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

    private func copyToken() -> Bool {
        guard let token = model.token else {
            tokenProblem = "Couldn't read the token."
            return false
        }
        tokenProblem = nil
        model.copy(token)
        return true
    }

    // MARK: About

    @ViewBuilder var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(AppVersion.current).textSelection(.enabled)
            }
            LabeledContent("Acknowledgements") {
                Button("Show…") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
            }
        }
    }
}
